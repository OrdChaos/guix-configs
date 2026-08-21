;;; niri application unit：用户桌面生命周期（home-niri-service-type，
;;; bash -l -c "exec niri --session"；profile 自动贡献 dbus/niri/
;;; xdg-desktop-portal-*/xwayland-satellite；requirement home-dbus）
;;; + niri 公开配置（config.kdl 入口 + common.kdl 通用配置，本目录
;;; colocate）。
;;;
;;; 配置树（docs/architecture/graphics.md）：
;;;   config.kdl   薄入口：include common.kdl + host.kdl(optional) +
;;;                noctalia.kdl(optional)（include 语义见文件头注释）
;;;   common.kdl   application-owned：全部机器无关行为
;;;   host.kdl     不由本模块生成——host/profile 层经 generic
;;;                extra-configuration-files 机制
;;;                （(guixcfg apps extra-config)）贡献（laptop 见
;;;                hosts/laptop.scm）；VM 无此文件
;;;   noctalia.kdl 运行时由 Noctalia 生成（唯一 owner = Noctalia；
;;;                本模块不安装、不声明）
;;;
;;; 经官方 home-xdg-configuration-files-service-type 以 source-
;;; relative local-file 声明（pinned Guix local-file 宏按出现处
;;; source directory 解析）——derived state，每次 fresh root/Home
;;; activation 恢复；不持久化、app 不是第二 authority。

(define-module (guixcfg apps niri definition)
               #:use-module (gnu home services)      ; home-xdg-configuration-files-service-type
               #:use-module (gnu home services niri) ; home-niri-service-type
               #:use-module (gnu services)           ; service
               #:use-module (guix gexp)              ; local-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%niri))

(define %niri
  (application
   (name 'niri)
   (home-services
    (list (service home-niri-service-type)
          ;; 共享 sink（home-xdg-configuration-files）经 Guix native
          ;; extension 贡献（simple-service → target；canonical target
          ;; 由 instantiate-missing-services 以 default '() 自动实例化
          ;; ——见 AGENT.md §15 / docs/architecture/applications.md）。
          (simple-service 'niri-xdg-config
                          home-xdg-configuration-files-service-type
                          `(("niri/config.kdl"
                             ,(local-file "config.kdl" "niri-config.kdl"))
                            ("niri/common.kdl"
                             ,(local-file "common.kdl" "niri-common.kdl"))))))))
