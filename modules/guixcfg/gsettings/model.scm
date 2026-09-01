;;; Repository-derived GSettings 模型（docs/architecture/gsettings.md）：
;;; application 在自己的 definition 中声明它负责的 GSettings；
;;; 仓库聚合、校验 ownership 并投影到 runtime dconf。
;;;
;;; 不变量（本轮定案）：
;;;   repository      = source of truth
;;;   GSettings 声明  = declarative desired state
;;;   dconf           = disposable runtime projection（~/.config/dconf
;;;                      MUST NOT be persisted）
;;;   reboot          = natural reset boundary
;;;   删除声明        = 当前 boot 内旧 runtime 值可残留，reboot 自然
;;;                     回到 schema default；不实现 generation
;;;                     managed-key tracking（有意设计，不是遗漏）。
;;;
;;; <gsettings-setting> 是 Phase 1 最小 record：schema / key / value。
;;; value 是 dconf/GSettings tooling 接受的 GVariant 文本表示
;;; （"true" / "12" / "'Adwaita'" / "['foo', 'bar']"）——本轮不设计
;;; GVariant 类型系统、不做 AST/constructor 层级。
;;;
;;; Ownership 硬规则：一个 (schema, key) = 恰好一个 application
;;; owner。重复声明（即使值相同）也 fail；不做 last-wins、不
;;; silently merge、不按 registry 顺序决定。
;;;
;;; Appearance 边界：org.gnome.desktop.interface 的 6 个动态外观键
;;; （color-scheme / gtk-theme / icon-theme / cursor-theme /
;;; cursor-size / font-name）由既有 appearance-sync
;;; （apps/gtk/definition.scm）独占——Noctalia light/dark 切换会
;;; 运行时改写它们，generic GSettings 声明同一键即 fail。

(define-module (guixcfg gsettings model)
               #:use-module (guix records)
               #:use-module (srfi srfi-1)  ; every、delete-duplicates、filter
               #:export (<gsettings-setting>
                         gsettings-setting make-gsettings-setting
                         gsettings-setting?
                         gsettings-setting-schema
                         gsettings-setting-key
                         gsettings-setting-value
                         valid-gsettings-setting?
                         validate-gsettings-ownership!
                         %appearance-owned-gsettings-keys
                         gsettings-desired-state))

;;; ── appearance 保留域 ──────────────────────────────────────
;;; 与 apps/gtk/definition.scm 的 %appearance-sync 逐键对应
;;; （tests/test-appearance.scm 以 fake gsettings 逐条断言）。
;;; generic GSettings 声明任何保留键 → ownership 冲突 fail。

(define %appearance-owned-gsettings-keys
  '(("org.gnome.desktop.interface" . "color-scheme")
    ("org.gnome.desktop.interface" . "gtk-theme")
    ("org.gnome.desktop.interface" . "icon-theme")
    ("org.gnome.desktop.interface" . "cursor-theme")
    ("org.gnome.desktop.interface" . "cursor-size")
    ("org.gnome.desktop.interface" . "font-name")))

;;; ── record ────────────────────────────────────────────────

(define-record-type* <gsettings-setting>
                     gsettings-setting make-gsettings-setting
                     gsettings-setting?
                     (schema gsettings-setting-schema)  ; string：GSettings schema id（如 org.gnome.TextEditor）
                     (key gsettings-setting-key)        ; string：schema 内的键名
                     (value gsettings-setting-value))   ; string：GVariant 文本表示（如 "true" / "'Adwaita'"）

(define (non-empty-string? s)
  (and (string? s) (> (string-length s) 0)))

(define (valid-gsettings-setting? setting)
  "SETTING 是结构合法的 <gsettings-setting>：schema/key/value 均为
  非空 string。schema 的 D-Bus 风格分段名与 value 的 GVariant 深度
  合法性不在本层——前者由 runtime 的 gsettings list-keys 校验
  （missing-schema），后者由 dconf load 自身接受性兜底。"
  (and (gsettings-setting? setting)
       (non-empty-string? (gsettings-setting-schema setting))
       (non-empty-string? (gsettings-setting-key setting))
       (non-empty-string? (gsettings-setting-value setting))))

;;; ── ownership 校验（硬规则）───────────────────────────────
;;; CONTRIBUTIONS = ((owner . <gsettings-setting>) ...)
;;; （apps/model.scm 的 applications-gsettings 输出形态；owner 是
;;; application name symbol——错误报告用，不塞进 record 重复存）。

(define (schema-key-id setting)
  (cons (gsettings-setting-schema setting)
        (gsettings-setting-key setting)))

(define (group-contributions-by-schema-key contributions)
  "CONTRIBUTIONS 按 (schema, key) 排序后把同键相邻项分组（排序后
  相同键必然相邻；返回按声明序的组列表，每项是 (owner . setting)
  子列表）。"
  (let ((sorted (sort contributions
                      (lambda (a b)
                        (let ((sa (gsettings-setting-schema (cdr a)))
                              (sb (gsettings-setting-schema (cdr b))))
                          (or (string< sa sb)
                              (and (string=? sa sb)
                                   (string< (gsettings-setting-key (cdr a))
                                            (gsettings-setting-key (cdr b))))))))))
    (if (null? sorted)
      '()
      (let loop ((remaining (cdr sorted))
                 (current (list (car sorted)))
                 (acc '()))
        (if (null? remaining)
          (reverse (cons current acc))
          (let ((next (car remaining)))
            (if (equal? (schema-key-id (cdar current))
                        (schema-key-id (cdr next)))
              (loop (cdr remaining) (cons next current) acc)
              (loop (cdr remaining) (list next)
                    (cons current acc)))))))))

(define (validate-gsettings-ownership! contributions)
  "CONTRIBUTIONS（(owner . setting) pairs）的 ownership 校验：
  1) 每个 setting 结构合法（fail-fast，报告 owner）；
  2) (schema, key) 全局唯一——重复即 fail（即使值相同），错误列出
     该键的全部 owner；
  3) 与 %appearance-owned-gsettings-keys 冲突即 fail（appearance-
     sync 独占的动态外观键不得进入 generic GSettings）。
  全部通过返回 #t。"
  (for-each (lambda (entry)
              (unless (valid-gsettings-setting? (cdr entry))
                (error "invalid gsettings setting declared by application"
                       (car entry) (cdr entry))))
            contributions)
  (for-each (lambda (group)
              (when (> (length group) 1)
                (let ((setting (cdar group))
                      (owners (map car group)))
                  (error "duplicate GSettings ownership (schema, key)"
                         (string-append (gsettings-setting-schema setting)
                                        " / "
                                        (gsettings-setting-key setting))
                         owners))))
            (group-contributions-by-schema-key contributions))
  (for-each (lambda (reserved)
              (let ((hits (filter (lambda (entry)
                                    (equal? (schema-key-id (cdr entry))
                                            reserved))
                                  contributions)))
                (unless (null? hits)
                  (error "gsettings key is owned by appearance-sync (dynamic desktop appearance)"
                         (string-append (car reserved) " / " (cdr reserved))
                         (map car hits)))))
            %appearance-owned-gsettings-keys)
  #t)

(define (gsettings-desired-state contributions)
  "CONTRIBUTIONS（(owner . setting) pairs）→ desired state 视图：
  排序后的 <gsettings-setting> 列表（schema 排序 → key 排序，
  registry 顺序无关；ownership 校验通过后调用）。"
  (validate-gsettings-ownership! contributions)
  (sort (map cdr contributions)
        (lambda (a b)
          (let ((sa (gsettings-setting-schema a))
                (sb (gsettings-setting-schema b)))
            (or (string< sa sb)
                (and (string=? sa sb)
                     (string< (gsettings-setting-key a)
                              (gsettings-setting-key b))))))))
