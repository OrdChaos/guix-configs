;;; 操作计划：把存储模型 + host policy 展开成一串有序步骤。
;;; 本模块只生成计划（纯函数），不执行；阶段 2 的 install.scm 负责执行，
;;; tools/disk-install.scm 的 plan/dry-run 子命令直接打印这里的输出。
;;; 对应 docs/operations/installation.md和 docs/architecture/storage.md。

(define-module (guixcfg storage plan)
               #:use-module (guixcfg storage model)
               #:use-module (guix records)  ; define-record-type*
               #:use-module (ice-9 format)  ; 带宽度的 format（~2d）
               #:use-module (srfi srfi-1)   ; iota
               #:export (<plan-step>
                         plan-step make-plan-step plan-step?
                         plan-step-id plan-step-summary plan-step-detail
                         storage-plan
                         plan->text display-plan))

;;; ────────────────────────────────────────────────────────────
;;; 计划步骤：id 是符号（阶段 2 按 id 分派执行），summary 给人看，
;;; detail 是一个关联列表（alist），携带执行所需的参数。
;;;
;;; 关联列表就是“键值对列表”：'((device . "/dev/vda") (size . 2147483648))，
;;; 用 (assq-ref detail 'device) 取值。

(define-record-type* <plan-step>
                     plan-step make-plan-step
                     plan-step?
                     (id      plan-step-id)
                     (summary plan-step-summary)
                     (detail  plan-step-detail
                              (default '())))

;;; ────────────────────────────────────────────────────────────
;;; 由 policy 和目标设备生成完整计划。
;;; 步骤顺序即执行顺序；调整顺序前先看 docs/operations/installation.md的流程。

(define (storage-plan policy device)
  "生成把空盘 DEVICE 安装成 POLICY 描述布局的有序步骤列表。"
  (let ((esp-size     (host-storage-policy-esp-size policy))
        (swap-size    (host-storage-policy-swapfile-size policy))
        (mapper-path  (string-append "/dev/mapper/" %luks-mapper-name)))
    (append
     (list
      ;; 安全闸门：validate.scm 的全部检查 + 人工输入完整设备路径确认。
      (plan-step (id 'confirm-target)
                 (summary "校验目标设备并要求人工确认")
                 (detail `((device . ,device))))
      (plan-step (id 'wipe)
                 (summary "清除磁盘上的旧分区表和签名")
                 (detail `((device . ,device))))
      ;; 一条 sgdisk 命令完成：GPT + ESP + 系统分区 + 类型码 + PARTLABEL。
      (plan-step (id 'partition)
                 (summary "创建 GPT、ESP 分区和加密系统分区")
                 (detail `((device . ,device)
                           (esp-size . ,esp-size))))
      (plan-step (id 'wait-udev)
                 (summary "等待 udev 出现新分区节点")
                 (detail `((device . ,device))))
      (plan-step (id 'format-esp)
                 (summary "格式化 ESP 为 VFAT")
                 (detail `((partlabel . ,%esp-partlabel)
                           (label . ,%esp-filesystem-label))))
      (plan-step (id 'luks-format)
                 (summary "初始化 LUKS2（交互输入密码）")
                 (detail `((partlabel . ,%system-partlabel)
                           (label . ,%luks-label))))
      (plan-step (id 'luks-open)
                 (summary "解锁 LUKS 到 device-mapper")
                 (detail `((partlabel . ,%system-partlabel)
                           (mapper . ,%luks-mapper-name))))
      (plan-step (id 'format-btrfs)
                 (summary "在加密卷上格式化 Btrfs")
                 (detail `((device . ,mapper-path)
                           (label . ,%btrfs-filesystem-label))))
      (plan-step (id 'mount-top)
                 (summary "临时挂载 Btrfs 顶层以创建子卷")
                 (detail `((device . ,mapper-path)))))
     
     ;; 8 个固定持久子卷（顺序来自 model.scm）。
     (map (lambda (sv)
            (plan-step (id 'make-subvolume)
                       (summary (string-append "创建持久子卷 " (subvolume-name sv)))
                       (detail `((name . ,(subvolume-name sv))))))
          %persist-subvolumes)
     
     (list
      (plan-step (id 'make-root-installing)
                 (summary "创建安装期 root 子卷")
                 (detail `((name . ,%root-installing-name))))
      (plan-step (id 'make-swapfile)
                 (summary "创建 Btrfs swapfile（NOCOW、不压缩、预分配）")
                 (detail `((subvolume . ,%swap-subvolume-name)
                           (size . ,swap-size))))
      (plan-step (id 'unmount-top)
                 (summary "卸载 Btrfs 顶层"))
      (plan-step (id 'mount-root)
                 (summary "挂载安装期 root 到 /mnt")
                 (detail `((name . ,%root-installing-name)
                           (target . "/mnt")))))
     
     ;; 每个持久子卷挂到 /mnt 下对应位置。
     ;; 例外：mount-at-install? 为 #f 的子卷（@persist-var-guix）在
     ;; init 期间不挂载——init 需要看到原生的目标目录，
     ;; 其内容由 commit-root 收进子卷（见 storage/commit.scm）。
     (map (lambda (sv)
            (plan-step (id 'mount-subvolume)
                       (summary (string-append "挂载 " (subvolume-name sv)
                                               " 到 /mnt" (subvolume-mount-point sv)))
                       (detail `((name . ,(subvolume-name sv))
                                 (target . ,(string-append "/mnt" (subvolume-mount-point sv)))
                                 (options . ,(subvolume-options sv))))))
          (filter subvolume-mount-at-install? %persist-subvolumes))
     
     (list
      (plan-step (id 'mount-esp)
                 (summary "挂载 ESP 到 /mnt/efi")
                 (detail `((partlabel . ,%esp-partlabel)
                           (target . "/mnt/efi"))))
      ;; 机器事实（docs/architecture/storage.md（固定命名事实））：LUKS UUID 等安装时生成的值，
      ;; 必须在 guix system init 之前写入（配置在构建期读取它）。
      (plan-step (id 'write-facts)
                 (summary "写入机器事实文件 /persist/system/facts/host.scm")
                 (detail `((target . "/mnt"))))
      (plan-step (id 'ready)
                 (summary "磁盘就绪，进入 guix system init"))))))

;;; ────────────────────────────────────────────────────────────
;;; 人类可读输出。

(define (display-plan plan)
  "把计划打印到当前输出端口。"
  (for-each
   (lambda (step n)
     (format #t "~2d. ~a [~a]\n" n (plan-step-summary step) (plan-step-id step))
     (for-each
      (lambda (kv)
        (format #t "      ~a: ~a\n" (car kv) (cdr kv)))
      (plan-step-detail step)))
   plan
   ;; iota 生成 (0 1 2 ...)，加一作为步骤编号。
   (map (lambda (i) (+ i 1)) (iota (length plan)))))

(define (plan->text plan)
  "把计划渲染成字符串（供测试和日志使用）。"
  (call-with-output-string
   (lambda (port)
     (parameterize ((current-output-port port))
                   (display-plan plan)))))
