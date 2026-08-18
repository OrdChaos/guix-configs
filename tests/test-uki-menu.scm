;;; Limine 菜单语义测试（boot-menu 收敛：公开 boot model 只有
;;; Normal / Recovery 两个用户启动项）。
;;;
;;; 覆盖：
;;;   T1  menu cardinality：生成后的 Limine 配置恰好两个用户启动项
;;;   T2  no historical entries：无 Previous/Old Root/Last Good/
;;;       @root-N 历史项
;;;   T11 Normal/Recovery 分别映射到正确 UKI 路径（CURRENT.EFI /
;;;       RECOVERY.EFI）与 boot mode（normal 缺省 / rootmode=recovery）
;;;
;;; 测试的是 limine-config-text（部署脚本实际使用的纯函数）的真实
;;; 文本输出，不是源码里的构造器数量。

(use-modules (guixcfg boot limine-menu) ; limine-config-text
             (ice-9 rdelim)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (config-entries text)
  "解析 Limine 配置文本中的用户启动项：'/' 开头的非缩进行。
返回 (label . 条目行) 列表。"
  (let loop ((lines (call-with-input-string text
                                            (lambda (p)
                                              (let l ((acc '()))
                                                (let ((line (read-line p)))
                                                  (if (eof-object? line)
                                                    (reverse acc)
                                                    (l (cons line acc))))))))
             (acc '()))
    (if (null? lines)
      (reverse acc)
      (let ((line (car lines)))
        (if (and (string-prefix? "/" line)
                 (not (string-prefix? "//" line)))
          (loop (cdr lines) (cons line acc))
          (loop (cdr lines) acc))))))

(define (entry-image-path text label)
  "返回 LABEL 条目（'/LABEL' 起始段）的 image_path 行；无则 #f。"
  (let loop ((lines (call-with-input-string text
                                            (lambda (p)
                                              (let l ((acc '()))
                                                (let ((line (read-line p)))
                                                  (if (eof-object? line)
                                                    (reverse acc)
                                                    (l (cons line acc))))))))
             (in-entry? #f))
    (cond
     ((null? lines) #f)
     ((and (string-prefix? "/" (car lines))
           (not (string-prefix? "//" (car lines))))
      (loop (cdr lines)
            (string=? (car lines) (string-append "/" label))))
     ((and in-entry? (string-prefix? "    image_path:" (car lines)))
      (car lines))
     (else (loop (cdr lines) in-entry?)))))

(test-begin "uki-menu")

;; ── T1/T2：Normal + Recovery 恰好两项，无历史项 ────────────
(test-assert "T1: config has exactly the Normal entry when Recovery absent"
             (let ((text (limine-config-text "A" #f)))
               (equal? '("/GNU Guix") (config-entries text))))

(test-assert "T1: config has exactly Normal + Recovery when Recovery present"
             (let ((text (limine-config-text "A" #t)))
               (equal? '("/GNU Guix" "/GNU Guix (Recovery)")
                       (config-entries text))))

(test-assert "T2: no historical/Last Good/old-root entries anywhere"
             (let ((text (limine-config-text "B" #t)))
               (not (or (string-contains text "Previous")
                        (string-contains text "previous")
                        (string-contains text "Last Good")
                        (string-contains text "last-good")
                        (string-contains text "Old Root")
                        (string-contains text "@root")
                        (string-contains text "PREV-")))))

;; ── T11：Normal/Recovery 的 UKI 路径与 boot mode ───────────
(test-assert "T11: Normal entry points at CURRENT.EFI in the target slot"
             (let ((text (limine-config-text "B" #t)))
               (string-contains (entry-image-path text "GNU Guix")
                                "/EFI/Guix/B/CURRENT.EFI")))

(test-assert "T11: Recovery entry points at the stable RECOVERY.EFI path"
             (let ((text (limine-config-text "B" #t)))
               (string-contains (entry-image-path text "GNU Guix (Recovery)")
                                "/EFI/Guix/RECOVERY.EFI")))

;; Recovery UKI 本身由部署脚本以 rootmode=recovery 构建（uki.scm 的
;; build-uki 调用）；Normal 用当前 cmdline（rootmode 缺省 = normal）。
;; 这里断言部署脚本产物级语义已在 K 测试/部署脚本覆盖；菜单文本层
;; 只负责两个入口的路径映射。

(test-end "uki-menu")
