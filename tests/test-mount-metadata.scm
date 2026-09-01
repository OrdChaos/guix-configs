;;; GVfs mount metadata 测试（(guixcfg system mount-metadata) +
;;; (guixcfg utils mountinfo)）：utab 条目生成与幂等重建、mount-
;;; metadata 服务只处理带 x-gvfs-trash 的 HOME persistence bind
;;; mounts（machine-state 不误获）、entry 格式与 libmount 的 utab
;;; 契约一致（SRC/TARGET/ROOT/OPTS 键值对 + mangle escaping）。

(use-modules (gnu system file-systems)
             (gnu services)
             (gnu services shepherd) ; shepherd-root-service-type、shepherd-service-*
             (guixcfg utils mountinfo)      ; runtime 原语
             (guixcfg system mount-metadata) ; 服务 + 常量
             (guixcfg system user-persistence)
             (guixcfg system machine-state-persistence)
             (ice-9 rdelim)      ; read-string
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "mount-metadata")

;; ── mountinfo 解析（SOURCE/ROOT 提取）────────────────────────
(define %sample-mountinfo
  "26 25 0:21 / /home/user rw,relatime - btrfs /dev/mapper/cryptroot rw
27 25 0:22 /user/Documents /home/user/Documents rw,relatime - btrfs /dev/mapper/cryptroot rw
28 25 0:22 /user/.local/share/keyrings /home/user/.local/share/keyrings rw,relatime - btrfs /dev/mapper/cryptroot rw
29 25 0:23 / /persist/data-home rw,relatime - btrfs /dev/mapper/cryptroot rw
")

(test-equal "parse-mountinfo extracts mount point, source and root"
            '(("/home/user" "/dev/mapper/cryptroot" "/")
              ("/home/user/Documents" "/dev/mapper/cryptroot" "/user/Documents")
              ("/home/user/.local/share/keyrings" "/dev/mapper/cryptroot" "/user/.local/share/keyrings")
              ("/persist/data-home" "/dev/mapper/cryptroot" "/"))
            (parse-mountinfo %sample-mountinfo))

(test-equal "mountinfo entries selected by target"
            '(("/dev/mapper/cryptroot" "/home/user/Documents" "/user/Documents"))
            (let ((entries (parse-mountinfo %sample-mountinfo)))
              (map (lambda (m)
                     (let ((hit (find (lambda (e)
                                        (string=? (car e) (cdr m)))
                                      entries)))
                       (list (cadr hit) (cdr m) (caddr hit))))
                   '(("/persist/data-home/user/Documents"
                      . "/home/user/Documents")))))

;; ── utab 条目生成（libmount 格式，含 ROOT）───────────────────
(define %sample-entries
  (gvfs-utab-entries
   '(("/persist/data-home/user/Documents"
      "/home/user/Documents" "/user/Documents")
     ("/persist/data-app/mpv/state"
      "/home/user/.local/state/mpv" "/user/.local/state/mpv"))
   %persistent-home-mount-options))

(test-equal "utab entry format (SRC TARGET ROOT OPTS + ownership marker)"
            '("SRC=/persist/data-home/user/Documents TARGET=/home/user/Documents ROOT=/user/Documents OPTS=x-gvfs-hide,x-gvfs-trash,x-guixcfg.home-persistence"
              "SRC=/persist/data-app/mpv/state TARGET=/home/user/.local/state/mpv ROOT=/user/.local/state/mpv OPTS=x-gvfs-hide,x-gvfs-trash,x-guixcfg.home-persistence")
            %sample-entries)

;; ── ownership marker（精确字段解析，非 substring 猜测）────────
(test-assert "marker-owned entry recognized"
             (owned-entry?
              (car %sample-entries)))
(test-assert "foreign entry with same desktop options but no marker is NOT owned"
             (not (owned-entry?
                   "SRC=/dev/sda1 TARGET=/mnt/other OPTS=x-gvfs-hide,x-gvfs-trash")))
(test-assert "OPTS order changes do not change ownership"
             (owned-entry?
              "SRC=/p TARGET=/t ROOT=/r OPTS=x-guixcfg.home-persistence,x-gvfs-hide"))
(test-assert "extra options alongside the marker keep ownership"
             (owned-entry?
              "SRC=/p TARGET=/t ROOT=/r OPTS=rw,x-guixcfg.home-persistence"))
(test-assert "marker text in SRC/TARGET/ROOT fields does not claim ownership"
             (not (owned-entry?
                   "SRC=/persist/x-guixcfg.home-persistence TARGET=/t ROOT=/r OPTS=rw")))

;; ── ensure-gvfs-utab!：按 marker 重建本服务条目（parameter 化）──
(define %utab-test-dir
  (string-append "/tmp/guixcfg-utab-" (number->string (getpid))))
(define %utab-test-path (string-append %utab-test-dir "/utab"))

(parameterize ((%gvfs-utab-path %utab-test-path))
              ;; 首次：全部写入
              (test-equal "first run writes all service entries"
                          2 (ensure-gvfs-utab! %sample-entries))
              ;; 重复：幂等（重建后仍是相同条目，无重复 TARGET）
              (test-equal "re-run is idempotent (same entry count)"
                          2 (ensure-gvfs-utab! %sample-entries))
              (let ((content (call-with-input-file %utab-test-path
                                                   (lambda (p) (read-string p)))))
                (test-assert "utab content contains both entries"
                             (and (string-contains content "TARGET=/home/user/Documents")
                                  (string-contains content "TARGET=/home/user/.local/state/mpv")))
                (test-assert "utab content has no duplicate TARGET"
                             (= 1 (length (filter (lambda (l)
                                                    (string-contains l
                                                                     "TARGET=/home/user/Documents"))
                                                  (string-split content #\newline)))))
                (test-assert "utab content carries the ownership marker"
                             (string-contains content %guixcfg-utab-ownership-marker)))
              ;; 场景 D：reconfigure 删除 consumer——旧 TARGET 随重建消失
              (test-equal "rebuild with fewer entries removes stale targets"
                          1 (ensure-gvfs-utab!
                             (list (car %sample-entries))))
              (let ((content (call-with-input-file %utab-test-path
                                                   (lambda (p) (read-string p)))))
                (test-assert "stale target removed after rebuild"
                             (and (string-contains content "TARGET=/home/user/Documents")
                                  (not (string-contains content
                                                        "TARGET=/home/user/.local/state/mpv")))))
              ;; 场景 E：不破坏其他 owner 的条目
              (call-with-output-file %utab-test-path
                                     (lambda (p)
                                       (display "SRC=/dev/sda1 TARGET=/mnt/other OPTS=rw,noatime\n"
                                                p)))
              (test-equal "rebuild preserves other owners' entries"
                          1 (ensure-gvfs-utab! (list (car %sample-entries))))
              ;; 场景 F：同桌面选项但无 marker 的外来条目也必须保留
              (call-with-output-file %utab-test-path
                                     (lambda (p)
                                       (display (string-append
                                                 "SRC=/dev/sdb1 TARGET=/mnt/foreign OPTS=x-gvfs-hide,x-gvfs-trash\n"
                                                 "SRC=/dev/sda1 TARGET=/mnt/other OPTS=rw,noatime\n")
                                                p)))
              (test-equal "rebuild preserves same-options foreign entries"
                          1 (ensure-gvfs-utab! (list (car %sample-entries))))
              (let ((content (call-with-input-file %utab-test-path
                                                   (lambda (p) (read-string p)))))
                (test-assert "foreign entry preserved"
                             (string-contains content "TARGET=/mnt/other"))
                (test-assert "same-options foreign entry preserved"
                             (string-contains content "TARGET=/mnt/foreign"))
                (test-assert "foreign entry not duplicated"
                             (= 1 (length (filter (lambda (l)
                                                    (string-contains l "TARGET=/mnt/other"))
                                                  (string-split content #\newline))))))
              ;; 清理
              (false-if-exception (delete-file-recursively %utab-test-dir)))

;; ── escaping（libmount mangle 规则）──────────────────────────
(test-assert "mangled utab entry encodes spaces"
             (let ((entry (car (gvfs-utab-entries
                                '(("/persist/data home/My Docs"
                                   "/home/user/My Docs"
                                   "/data home/My Docs"))
                                %persistent-home-mount-options))))
               (string-contains entry "SRC=/persist/data\\040home/My\\040Docs")))

(test-equal "mangle/unmangle round-trip (space tab newline backslash)"
            "/persist/data home\twith\\slash\nend"
            (unmangle (mangle "/persist/data home\twith\\slash\nend")))

;; ── mount-metadata 服务：只处理带 x-gvfs-trash 的 HOME bind ──
(define %user-fss (user-persistence-file-systems "user"))
(define %machine-fss
  (machine-state-persistence-file-systems
   (list (machine-state-persistence-rule
          (name 'example)
          (backing "example/state")
          (consumer "/etc/example")))))

(define %meta-svc (gvfs-mount-metadata-service %user-fss))
(define %machine-meta-svc (gvfs-mount-metadata-service %machine-fss))

(test-assert "user persistence mounts produce a metadata service"
             (and %meta-svc
                  (eq? 'gvfs-mount-metadata
                       (service-type-name (service-kind %meta-svc)))))
(test-assert "machine-state mounts produce NO metadata service"
             (not %machine-meta-svc))
(test-assert "metadata service is one-shot after file-systems"
             (let ((svc (car (service-value %meta-svc))))
               (and (eq? 'gvfs-mount-metadata
                         (car (shepherd-service-provision svc)))
                    (member 'file-systems (shepherd-service-requirement svc))
                    (shepherd-service-one-shot? svc))))

;; ── machine-state 的 file-system 无 gvfs options ─────────────
(test-assert "machine-state mounts carry no gvfs desktop options"
             (every (lambda (fs)
                      (not (string-contains (or (file-system-options fs) "")
                                            "x-gvfs-")))
                    %machine-fss))

;; ── consumer-side integration（userns + 生产代码 + libmount
;;    merge + gio trash）────────────────────────────────────────
;; 保护历史回归：缺 ROOT 的 utab 无法被 libmount merge（GIO 看不到
;; x-gvfs-trash → trash 被拒）。测试调用生产实现（mount-metadata
;; 的生成/写入函数），经 time-machine repl 在 userns 内执行，真实
;; bind mount + 真实 gio。
(define (command-available? cmd)
  (zero? (false-if-exception
          (system* "sh" "-c"
                   (string-append "command -v " cmd " >/dev/null 2>&1")))))

(define (userns-available?)
  (zero? (false-if-exception (system* "unshare" "-rm" "true"))))

(if (and (command-available? "unshare")
         (command-available? "gio")
         (userns-available?))
  (let* ((root "/tmp/guixcfg-it")
         (gen-script (string-append root "/gen-utab.scm"))
         (result
          (system* "unshare" "-rm" "sh" "-c"
                   (string-append
                    "set -e; "
                    "R=" root "; rm -rf $R; mkdir -p $R/home $R/persist; "
                    "export HOME=$R/home XDG_DATA_HOME=$R/home/.local/share; "
                    "mkdir -p $XDG_DATA_HOME /run/mount; "
                    "mount -t tmpfs tmpfs-run /run/mount; "
                    "mount -t tmpfs -o size=16M tmpfs-persist $R/persist; "
                    "mkdir -p $R/persist/Documents $R/home/Documents; "
                    "mount --bind $R/persist/Documents $R/home/Documents; "
                    ;; 生产代码生成并写入 utab（userns 内读 mountinfo）
                    "cat > " gen-script " <<'SCM'\n"
                    "(add-to-load-path (string-append (getcwd) \"/modules\"))\n"
                    "(use-modules (guixcfg utils mountinfo)\n"
                    "         (guixcfg system mount-metadata))\n"
                    "(ensure-gvfs-utab!\n"
                    " (gvfs-utab-entries\n"
                    "  (mountinfo-entries-for\n"
                    "   '((\"" root "/persist/Documents\" . \"" root "/home/Documents\")))\n"
                    "  %persistent-home-mount-options))\n"
                    "SCM\n"
                    "guix time-machine -C channels.lock.scm -- repl -L modules "
                    gen-script " || exit 9; "
                    "grep -q 'ROOT=' /run/mount/utab || exit 10; "
                    "echo it > $R/home/Documents/it.txt; "
                    "gio trash $R/home/Documents/it.txt || exit 11; "
                    "test -d $R/home/Documents/.Trash-* || exit 12; "
                    "ls $R/home/Documents/.Trash-*/files/it.txt >/dev/null 2>&1 || exit 13"))))
    (test-assert "integration: production utab enables gio trash on \
persistent bind mount"
                 (zero? result))
    ;; 清理
    (false-if-exception (system* "rm" "-rf" root)))
  (test-skip "consumer-side integration requires unshare userns + gio; skipped"))

(test-end "mount-metadata")
