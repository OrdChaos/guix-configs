;;; GSettings → dconf keyfile 序列化（docs/architecture/gsettings.md
;;; Projection backend）：managed declarations 的确定性渲染，唯一
;;; 消费方是 `dconf load /`（经 stdin）。
;;;
;;; dconf keyfile 路径规则：schema id 的 '.' 分段对应 dconf path 的
;;; '/' 分段（org.gnome.TextEditor → org/gnome/TextEditor）；每组
;;; `[path]` 头 + 逐行 `key=value`。
;;;
;;; value 是 declaration 里作者写定的 GVariant 文本（Phase 1 不做
;;; GVariant 类型系统）：原样透传、不做转义——引用型值（字符串/
;;; enum）由作者按 GVariant 文本规范书写（如 "'Adwaita'"）。
;;;
;;; 确定性：schema 排序 → key 排序；registry/application 顺序与
;;; 输出无关；相同声明 → byte-identical（测试保证）。
;;;
;;; 绝不生成/管理 ~/.config/dconf/user：不写二进制 DB、不 symlink、
;;; 不直接落文件——dconf load 是唯一 mutation 后端。

(define-module (guixcfg gsettings serialize)
               #:use-module (guixcfg gsettings model)
               #:use-module (srfi srfi-1)   ; every
               #:use-module (srfi srfi-13)  ; string-split、string-join、string-null?
               #:export (gsettings-schema->dconf-path
                         serialize-gsettings-keyfile))

(define (gsettings-schema->dconf-path schema)
  "GSettings schema id → dconf path（'.' → '/'）。"
  (string-join (string-split schema #\.) "/"))

(define (gsettings-keyfile-lines settings)
  "SETTINGS（<gsettings-setting> 列表，须已排序）→ keyfile 行列表
  （'[path]' 组头 + 'key=value'）。"
  (if (null? settings)
    '()
    (let loop ((remaining settings)
               (current-schema (gsettings-setting-schema (car settings)))
               (current-lines '())
               (acc '()))
      (if (null? remaining)
        (reverse (cons (cons (string-append
                              "["
                              (gsettings-schema->dconf-path current-schema)
                              "]")
                             (reverse current-lines))
                       acc))
        (let* ((setting (car remaining))
               (schema (gsettings-setting-schema setting)))
          (if (string=? schema current-schema)
            (loop (cdr remaining)
                  current-schema
                  (cons (string-append (gsettings-setting-key setting)
                                       "="
                                       (gsettings-setting-value setting))
                        current-lines)
                  acc)
            (loop (cdr remaining)
                  schema
                  (list (string-append (gsettings-setting-key setting)
                                       "="
                                       (gsettings-setting-value setting)))
                  (cons (cons (string-append
                               "["
                               (gsettings-schema->dconf-path current-schema)
                               "]")
                              (reverse current-lines))
                        acc))))))))

(define (serialize-gsettings-keyfile settings)
  "SETTINGS（<gsettings-setting> 列表）→ dconf keyfile 文本（确定性：
  内部按 schema/key 排序后渲染，输入顺序无关）。空列表 → 空串。"
  (let ((sorted (sort settings
                      (lambda (a b)
                        (let ((sa (gsettings-setting-schema a))
                              (sb (gsettings-setting-schema b)))
                          (or (string< sa sb)
                              (and (string=? sa sb)
                                   (string< (gsettings-setting-key a)
                                            (gsettings-setting-key b)))))))))
    (if (null? sorted)
      ""
      (let ((sections
             (map (lambda (group)
                    (string-append (car group) "\n"
                                   (string-join (cdr group) "\n")))
                  (gsettings-keyfile-lines sorted))))
        (string-append (string-join sections "\n") "\n")))))
