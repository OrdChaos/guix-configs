;;; Machine-id（/etc/machine-id）纯逻辑：格式校验、生成、持久化状态机。
;;; 本模块是纯机制——不知道 machine-id 的具体路径（canonical/consumer
;;; 由调用方传入）、不做任何 gnu/guix 重依赖（closure 必须保持极小：
;;; activation 脚本的 module-import 会合并本模块闭包，引入 gnu packages
;;; 会让 module-import-compiled 拉入 rust-crates 等巨型模块并在构建期
;;; 因 patch 路径缺失失败——2026-08-30 实测）。
;;;
;;; 语义（docs/architecture/persistence.md（Machine identity））：
;;;   1. canonical 缺失（新机器/首次安装）→ 生成一次，原子写入
;;;      （0444）；之后永不重新生成；
;;;   2. canonical 已存在 → 绝不覆盖（防覆盖；重新生成 = 悄悄更换
;;;      机器身份）；
;;;   3. canonical 损坏/非法 → fail closed（报错并给出处置方式，不
;;;      自动重新生成）；
;;;   4. consumer（/etc/machine-id）← canonical 投影：缺失/空/损坏/
;;;      不一致一律原子替换为 canonical。空或损坏的 /etc/machine-id
;;;      会让 pinned Guix D-Bus activation 的 dbus-uuidgen --ensure
;;;      直接失败（INVALID_FILE_CONTENT，dbus 1.16.2 不重建非法文件）
;;;      → 整次 activation 失败——投影顺带自愈 reused root（recovery）
;;;      里的旧/坏值。
;;;
;;; 生成用系统语义工具 dbus-uuidgen（pinned dbus 包；无参数 = 生成新
;;; UUID 打印到 stdout，32 hex + 换行）——不做自定义 UUID 生成（格式
;;; 契约以 dbus 的实现为准）。

(define-module (guixcfg utils machine-id)
               #:use-module (guix build utils)        ; mkdir-p
               #:use-module (guixcfg utils atomic-file) ; atomic-write-file!
               #:use-module (ice-9 popen)             ; open-pipe*（非 Guile core，AGENT.md §3）
               #:use-module (ice-9 rdelim)            ; read-line、read-string（非 Guile core）
               #:export (machine-id-valid?
                         normalize-machine-id
                         read-machine-id-file
                         generate-machine-id
                         ensure-machine-id!
                         project-machine-id!))

;;; ────────────────────────────────────────────────────────────
;;; 格式：与 dbus 的 machine-id 契约一致（dbus-uuidgen 输出 = 32 个
;;; hex 字符；_dbus_read_uuid_file_without_creating 对内容 chop white
;;; 后必须恰好 32 hex，长度不符即 INVALID_FILE_CONTENT）。

(define (string-trim-whitespace s)
  "去掉 S 两端的空白（与 dbus _dbus_string_chop_white 语义对齐；
纯 Guile core 实现——char-whitespace? 是 Guile core primitive，
不引 SRFI-13）。"
  (let ((len (string-length s)))
    (let loop ((start 0))
      (if (and (< start len)
               (char-whitespace? (string-ref s start)))
        (loop (+ start 1))
        (let loop ((end len))
          (if (and (> end start)
                   (char-whitespace? (string-ref s (1- end))))
            (loop (- end 1))
            (substring s start end)))))))

(define (hex-digit? c)
  "C 是否是 hex 字符（0-9 a-f A-F）。"
  (or (char-numeric? c)
      (and (char>=? c #\a) (char<=? c #\f))
      (and (char>=? c #\A) (char<=? c #\F))))

(define (machine-id-valid? s)
  "S 是否是合法 machine-id 内容：trim 空白后恰好 32 个 hex 字符。"
  (let ((s (string-trim-whitespace s)))
    (and (= 32 (string-length s))
         (let loop ((i 0))
           (or (= i 32)
               (and (hex-digit? (string-ref s i))
                    (loop (+ i 1))))))))

(define (normalize-machine-id s)
  "S 的 normalized 形式（trim 空白后的 32 hex 字符串）；非法返回 #f。"
  (let ((s (string-trim-whitespace s)))
    (and (machine-id-valid? s) s)))

(define (read-machine-id-file path)
  "PATH 的 machine-id 内容（normalized）。
缺失 → #f；存在但非法/不可读/不是文件 → 'invalid。
不抛错（调用方决定 fail-closed 还是按 'invalid 处理）。"
  (if (file-exists? path)
    (catch #t
      (lambda ()
        (or (normalize-machine-id (call-with-input-file path read-string))
            'invalid))
      (lambda (k . args) 'invalid))
    #f))

;;; ────────────────────────────────────────────────────────────
;;; 生成：dbus-uuidgen 可执行路径由调用方注入（激活脚本里是
;;; (file-append dbus "/bin/dbus-uuidgen") 的 store 路径）。

(define (generate-machine-id uuidgen)
  "用 UUIDGEN（dbus-uuidgen 可执行路径）生成 machine-id 内容。
生成失败或输出非法立即抛错——非法的 ID 绝不落盘。"
  (let* ((port (open-pipe* OPEN_READ uuidgen))
         (line (read-line port))
         (status (close-pipe port)))
    (unless (zero? status)
      (error "dbus-uuidgen failed" uuidgen status))
    (or (normalize-machine-id line)
        (error "dbus-uuidgen produced an invalid machine-id" line))))

;;; ────────────────────────────────────────────────────────────
;;; 状态机（可在测试中以临时目录 + 注入生成器直接调用）。

(define (ensure-machine-id! canonical generate)
  "确保 CANONICAL 持久文件存在且合法。
  - 缺失 → 调 GENERATE（thunk，返回合法 machine-id）生成一次，原子
    写入（0444）；之后永不重新生成；
  - 已存在且合法 → 原样返回，绝不覆盖；
  - 已存在但非法 → 抛错（fail closed：机器身份不得静默更换；人工
    处置：备份/恢复 canonical，或显式删除后重启重新生成）。
返回 canonical 内容。"
  (let ((existing (read-machine-id-file canonical)))
    (cond
      ((string? existing) existing)
      ((eq? existing 'invalid)
       (error "persistent machine-id is corrupt; refusing to regenerate \
(machine identity must not change silently). Restore it or delete it \
explicitly to mint a fresh identity" canonical))
      (else
       (let ((id (generate)))
         (unless (string? id)
           (error "machine-id generator returned no valid id" id))
         (mkdir-p (dirname canonical))
         (atomic-write-file! canonical
                             (lambda (port) (display id port) (newline port)))
         (chmod canonical #o444)
         id)))))

(define (project-machine-id! canonical consumer)
  "把 CANONICAL 投影到 CONSUMER（/etc/machine-id）：
缺失/空/损坏/不一致 → 原子替换为 canonical（0444）；一致 → 不动。
返回 canonical 内容。"
  (let ((id (read-machine-id-file canonical)))
    (unless (string? id)
      (error "cannot project machine-id; canonical missing or corrupt"
             canonical))
    (let ((current (read-machine-id-file consumer)))
      (unless (and (string? current) (string=? id current))
        (mkdir-p (dirname consumer))
        (atomic-write-file! consumer
                            (lambda (port) (display id port) (newline port)))
        (chmod consumer #o444)))
    id))
