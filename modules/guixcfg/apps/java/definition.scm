;;; Java application unit：多版本 JDK 共存（Java 8 / 17 / 21 / 24），
;;; 全部由 pinned guix 提供（gnu packages java——nonguix/virelith 无
;;; Java 包；不引入第三方 JDK 分发、不自建 distribution）。
;;;
;;; 版本事实（recon 2026-09，pinned guix 45a0e43）：
;;;   - Java 8  = icedtea-8：OpenJDK 8 的 IcedTea 构建。注意包变量名
;;;     与 CLI spec 不同——package name 是 "icedtea"、version
;;;     3.19.0，`guix build icedtea-8` 是 unknown package，必须写
;;;     icedtea@3.19.0；
;;;   - 17/21/24 = openjdk17 / openjdk21 / openjdk24：三个包的 name
;;;     都是 "openjdk"，只有 version 不同（17.0.10 / 21.0.2 /
;;;     24.0.1）；
;;;   - 四者 license 均 GPLv2+；bordeaux 有全部 substitute（实测
;;;     637 MB，无本地编译）。
;;;
;;; 输出结构与投影（gnu/packages/java.scm 实证）：所有 JDK 包 outputs =
;;; ("out" "jdk" "doc")；"out" 是 JRE image（bin/java 等运行时）、"jdk"
;;; 是完整 JDK image（bin/java + bin/javac/jar/javadoc + jmods/include）。
;;;   - profile：只装**默认版本**的 "jdk" output（output tuple 写法与
;;;     apps/gtk 的 (list glib "bin") 同款）——`java` 与 `javac` 同时
;;;     可用，且 JAVA_HOME 指向同一目录（profile 的 java 就是
;;;     $JAVA_HOME/bin/java）；不装 "out"（同一包两个 output 都含
;;;     bin/java，union-build 只会 first-wins）；
;;;   - javaNN wrapper：指向各版本 package 的**默认 output**（即 "out"
;;;     JRE image 的 bin/java）。理由见下（store reference 语义）；
;;;     launcher 本身同版本同行为——wrapper 的职责是"选版本跑 JVM"，
;;;     完整 JDK（javac/jmods）由默认版本 + JAVA_HOME 承担。
;;;
;;; store reference 语义（pinned Guix 45a0e43 实测，2026-09）——
;;; **非默认 output 会变成不被 GC 追踪的裸字符串**：
;;;   - `#$(gexp-input PKG "jdk")` / `#$(file-append (gexp-input PKG
;;;     "jdk") ...)` 在 gexp 中的展开文本是正确的 jdk 路径，但生成的
;;;     derivation 只登记 `(PKG.drv, ["out"])` 作为 input，产物
;;;     references 里没有 jdk output（实测 `guix gc --references`
;;;     只列 guile）——`guix gc` 之后 wrapper 里的路径会悬空，且
;;;     profile 里也没人引用它（同 (name,output) 的第二个 openjdk 版本
;;;     进不了 profile，见下）；
;;;   - 反之 `#$(file-append PKG "/bin/java")`（默认 output）同时给出
;;;     正确路径 **和** 登记在案的 store reference（实测 references
;;;     含 openjdk-*）。
;;;   因此：wrapper 用默认 output（可被 GC 追踪）；JAVA_HOME 指向
;;;   默认版本的 "jdk" output——它由 profile 的 `(list %default-java
;;;   "jdk")` manifest entry 提供 store reference（**这个 profile
;;;   entry 是 JAVA_HOME 的 GC 存活前提**，两者必须成对保留）。
;;;
;;; 为什么四个 JDK 不能同时进 home-packages（2026-09 实测）：
;;;   - 同名同 output → guix/profiles.scm 的 check-for-collisions（以
;;;     (name, output) 为键、item 不同即冲突）直接抛
;;;     &profile-collision-error：openjdk17:jdk + openjdk21:jdk 的
;;;     manifest 在 profile-derivation 阶段即失败（fail fast）；三个
;;;     openjdk 包的 package name 都是 "openjdk"，任何同名 output 都
;;;     撞（jdk/doc 都一样）；
;;;   - 即使包名不同（如 icedtea:jdk + openjdk21:jdk）绕过该检查，
;;;     guix/build/union.scm 的 resolve-collision/default 对同名文件
;;;     （bin/java、bin/javac、lib/**）只警告 "collision encountered"
;;;     并 first-wins——profile 里静默留下其中一个版本（实测 bin/java
;;;     = icedtea，即 Java 8）。那正是本设计要消除的"隐式全局版本
;;;     选择"。
;;;   因此 profile 只承载声明的默认版本；其余版本以 wrapper 暴露，
;;;   每个 wrapper 明确指向自己那个版本的 store launcher。
;;;
;;; 默认 Java 是**声明式选择**：%default-java（本文件是唯一
;;; authority）。改这一行 → 下一次 Home generation 的 profile
;;; java/javac 与 JAVA_HOME 同时跟随；非默认版本 wrapper 不受影响。
;;;
;;; 稳定访问名：~/.local/bin/java8|17|21|24（program-file wrapper，
;;; build 期注入 store 路径——仓库不硬编码 store 字面量，apps/
;;; polkit-gnome 同款）。只生成 `javaNN`：launcher/工具取的是 java
;;; **可执行文件**路径；javac/jar 等属"用哪个版本编什么"的场景，默认
;;; 版本已由 profile 直接提供。若要给某版本加 javac，在
;;; %java-version-table 的 wrapper 生成里加一项即可（不预生成 4×N
;;; 个 wrapper）。~/.local/bin 进 PATH 的唯一 owner 是 apps/
;;; polkit-gnome 的 PATH 贡献（xsettingsd/gtk 同款约定）——本单元
;;; 不声明第二次 PATH。
;;;
;;; JAVA_HOME：默认 JDK 的 "jdk" output（home-environment-variables
;;; 共享 sink 的 native extension，build 期注入 store 路径——不是
;;; 运行时探测）。无 shell startup 探测（不 which/readlink/PATH 顺序
;;; 推断）；额外版本不覆盖它（要用 java8 时直接 java8，JAVA_HOME 仍是
;;; 默认）。

(define-module (guixcfg apps java definition)
               #:use-module (gnu home services) ; home-files / home-environment-variables
               #:use-module (gnu packages java) ; icedtea-8、openjdk17/21/24
               #:use-module (gnu services)      ; simple-service
               #:use-module (guix gexp)         ; gexp-input、program-file、ungexp
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%java8 %java17 %java21 %java24
                                %default-java %java-version-table
                                java-command-program java-home-gexp
                                %java))

;; ── 版本事实源（major → JDK 包）─────────────────────────────
;; 全部 JDK（含 JRE 内容的 image 由 "jdk" output 承载；
;; 不声明纯 JRE 包——Minecraft/modding/Gradle 需要完整 JDK）。
(define %java8 icedtea-8)  ; Java 8（IcedTea 3.19.0）
(define %java17 openjdk17) ; 17.0.10
(define %java21 openjdk21) ; 21.0.2
(define %java24 openjdk24) ; 24.0.1

;; 默认 Java：声明式选择。profile 的 java/javac 与 JAVA_HOME 都跟随
;; 这里；非默认版本 wrapper 与之无关。
(define %default-java %java21)

;; 全版本表（含默认版本）：脚本可以直接写显式版本（java21），不必依赖
;; PATH 顺序；默认版本的 java21 wrapper 与该版本的 profile java 同版本
;; （21.0.2），只是投影的 output 不同（wrapper = JRE image launcher，
;; profile = 完整 JDK image——见文件头）。
(define %java-version-table
  (list (cons 8 %java8)
        (cons 17 %java17)
        (cons 21 %java21)
        (cons 24 %java24)))

(define (java-command-program major jdk)
  "返回 `javaMAJOR` wrapper（program-file）：exec JDK 包默认 output
（JRE image）的 bin/java，参数原样转发（-version/--version、JVM 选项、
classpath 等）。file-append 在 build 期注入 store 路径 **并登记 store
reference**（非默认 output 只会嵌入裸字符串、GC 回收后悬空——见文件头
store reference 一节）。"
  (program-file
   (string-append "java" (number->string major))
   #~(apply execl
       #$(file-append jdk "/bin/java")
       #$(string-append "java" (number->string major))
       (cdr (command-line)))))

(define (java-home-gexp jdk)
  "默认 JDK 的 \"jdk\" output 目录（JAVA_HOME 值）——gexp，ungexp 的
store 路径在 build 期展开。该 output 的 store reference 由 profile 的
`(list %default-java \"jdk\")` manifest entry 提供（两者成对保留）。"
  (gexp (ungexp (gexp-input jdk "jdk"))))

(define %java
  (application
   (name 'java)
   ;; 只装默认版本的 "jdk" output：java + javac + jmods/include 同时
   ;; 可得，且与 JAVA_HOME 同一目录（profile 里不放第二个 JDK——
   ;; 同名 output 冲突/first-wins，见文件头）。
   (home-packages (list (list %default-java "jdk")))
   (home-services
    (list ;; 每个版本的稳定访问名（home-files；~/.local/bin 的 PATH
     ;; 贡献归 apps/polkit-gnome）。
     (simple-service
      'java-version-wrappers
      home-files-service-type
      (map (lambda (entry)
             ;; 注意：home-files 条目是 **(target source) 两元素
             ;; list**（不是 dotted pair——symlink-manager 的
             ;; match 只接受 2 元素 list；env vars 才是 pair）。
             (list (string-append ".local/bin/java"
                                  (number->string (car entry)))
                   (java-command-program (car entry) (cdr entry))))
           %java-version-table))
          ;; JAVA_HOME = 默认 JDK 的 "jdk" output（声明值，非运行时
          ;; 探测；额外版本不覆盖它）。
          (simple-service
           'java-home
           home-environment-variables-service-type
           `(("JAVA_HOME" . ,(java-home-gexp %default-java))))))))
