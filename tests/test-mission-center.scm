;;; Mission Center application 结构测试：virelith package 来源、
;;; 无状态（GSettings-only）边界、registry 启用、desktop entry 常量。
;;;
;;; 覆盖：
;;;   MC1  %mission-center 安装 virelith 的 mission-center@1.2.0
;;;   MC2  registry 恰好启用一次，且聚合进 home packages
;;;   MC3  无 persistence rule（设置全在 GSettings/dconf）
;;;   MC4  无 system service 贡献（用户态应用）
;;;   MC5  desktop entry 常量与包内产物一致
;;;   MC6  definition 无 /gnu/store hash 字面量

(use-modules (guixcfg apps mission-center definition)
             (guixcfg apps model)       ; application-home-packages 等
             (guixcfg apps registry)    ; %applications
             (guix packages)            ; package-name、package-version、package-location
             (guix diagnostics)         ; location->string（location-file 未导出）
             (srfi srfi-1)
             (ice-9 rdelim)             ; read-string
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "mission-center")

;; ── MC1：package 来源 ────────────────────────────────────────
(test-assert "MC1: home-packages is the locally patched mission-center"
              (let ((pkgs (application-home-packages %mission-center)))
                (and (= 1 (length pkgs))
                     (let* ((p (car pkgs))
                            (loc (package-location p)))
                       (and (string=? "mission-center" (package-name p))
                            (string=? "1.2.0" (package-version p))
                            (string-contains (location->string loc)
                                             "guixcfg"))))))

;; ── MC2：registry 启用 ───────────────────────────────────────
(test-assert "MC2: registry enables mission-center exactly once"
             (= 1 (count (lambda (a) (eq? a %mission-center))
                         %applications)))

(test-assert "MC2: mission-center contributes into home packages"
             (let ((p (car (application-home-packages %mission-center))))
               (member p (applications-home-packages %applications))))

;; ── MC3：无 persistence ─────────────────────────────────────
;; 全部状态在 GSettings schema io.missioncenter.MissionCenter，由
;; generic dconf 投影管理；无文件型应用数据 → 不应有 bind rule。
(test-equal "MC3: no persistence rules"
            '()
            (application-persistence %mission-center))

;; ── MC4：无 system service ──────────────────────────────────
(test-equal "MC4: no system service contributions"
            '()
            (application-system-services %mission-center))

;; ── MC5：desktop entry 常量 ─────────────────────────────────
(test-equal "MC5: desktop entry matches the packaged app id"
            "io.missioncenter.MissionCenter.desktop"
            %mission-center-desktop-entry)

;; ── MC6：definition 无 store hash 字面量 ────────────────────
(test-assert "MC6: definition contains no /gnu/store hash literal"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/mission-center/definition.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "/gnu/store/"))))

(test-end "mission-center")
