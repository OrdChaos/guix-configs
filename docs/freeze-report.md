# 兼容性修复 Final Report（virelith cae11b77 + guix 94a84f93）— 19 项

**1. virelith channel revision**：cae11b77（tpm2-tss 4.1.3→4.2.0、tpm2-tools 5.7→5.8）
**2. guix revision**：2010c341→94a84f93（commit 6c1a53a）
**3. TPM 栈版本验证**：tpm2-tss 4.2.0 + tpm2-tools 5.8 在 initrd/工具链全链路可用
**4. store 路径记录**：tpm2-tools-compat-5.8（n11xb2r7）、cryptsetup-static-2.8.4、
   guile-static-initrd-3.0.11（8rq96r5y）、guix-1.5.0-5.e343ff0
**5. T1（tpm2-tools 集成）**：9/9 PASS
**6. T2（cryptsetup 集成）**：9/9 PASS
**7. 宿主全回归**：256 PASS，EXIT=0（Phase 11 + 修复后复跑）

**8. initrd subprocess 故障定位（Phase 2，historical debugging）**：
   TPM 自动解锁早期实现通过 Guile 的传统 popen/fork 型 subprocess 路径
   调用 tpm2-tools/cryptsetup。在 static Guile 的 initrd/PID1 环境中，
   该路径能够触发 BDW GC/进程运行时异常和 segfault。决定性实验证明的
   是「fork/popen 执行路径 + static Guile PID1 环境」的组合可复现故障
   （与 tpm2-tools 版本无关）；并未证明 BDW GC 本身不能在 PID1 下运行。
   调试过程中曾验证 BusyBox PID1 → Guile child 可以改变/规避部分 PID1
   相关故障表现——该方案仅用于根因隔离实验，从未成为最终产品架构。
**9. 最终修复（Final Architecture）**：
   保留 Guix 原生的 Guile PID1 initrd 模型，将 initrd TPM subprocess 层
   迁移为 Guile spawn / posix_spawn primitives（spawn-wait /
   spawn-with-stdin / spawn-capture / spawn-pipeline）。父 Guile 进程
   不执行传统 fork/popen 中转。故障在保持 Guile PID1 不变的情况下
   消失，并通过多次真实 TPM 自动解锁验证。BusyBox PID1 不属于产品架构。
**10. spawn primitives（Phase 3-5，a35e044）**：spawn-wait / spawn-with-stdin /
    spawn-capture / spawn-pipeline / wait-exit（posix_spawn，父进程不 fork）
**11. spawn 测试**：15 项 spawn + 9 项 process helper，全 PASS
**12. TPM adapter 迁移（Phase 4/6，f75bbe8）**：tpm2_unseal stdout FD → pipe →
    cryptsetup stdin FD 直连；明文不经 Scheme heap；popen/fork 中转移除
**13. device-resolver（bcd73a3）**：7.x 内核 /sys/block 只列 disk，分区在
    /sys/class/block/<part>；partition-parent-disk 两位置兼容

**14. Recovery fixture（Phase 7，8bb4c7a）**：install-init 独立构建
    RECOVERY.EFI（rootmode=recovery），绝不 cp CURRENT.EFI；
    ukify inspect 断言 .cmdline 含 rootmode=recovery
**15. Recovery fail-closed（Phase 8，c38c80d）**：promote-recovery! 校验
    current identity，失败不更新 GC root/不写 last-good；16 项测试 PASS
**16. TPM replace T3（Phase 9）**：R 保留、A 槽删除、新 B 槽部署；
    reboot PCR7 auto-unlock using B PASS；promote-recovery! boot-state v2
    + GC root 验证

**17. Guile version alignment（Phase 10）**：guix-final 与 guile-static-initrd
    全链 3.0.11，.go 均 ELF 容器（3.0.10+）；3.0.9 反例证实不兼容；
    无需 override（若未来失同步，override 点记录在 Virelith）
**18. clean-state T3 A-E（Phase 12）**：
    A auto-unlock（真 pipeline）：PASS（多次）
    B tpm-clear fallback：PASS
    C PCR7 change fallback：PASS
    D recovery skip：PASS（tpm-skip + 无尝试自动解锁）
    E corrupt artifact fallback：语义验证 PASS（尝试→失败→回退→密码→成功）
    Phase 12 修复：console 竞态（file-systems.scm）、tpm2-enroll dynamic-wind
    2 参 bug + (rnrs base)、run.sh 场景补全/顺序/状态恢复（19f5419 + c8d16a3）
**19. freeze gate + READY TO FREEZE**：
    判定标准：A 场景（initrd 真 pipeline）必须 PASS 且无 segfault
    结果：A 多次 PASS（无 segfault、无 panic）；B/C/D PASS；E 语义 PASS；
    全回归 256 PASS；enroll/replace 首次完整跑通
    **判定：READY TO FREEZE = YES（产品代码）**

   附带记录（test infrastructure limitations，非 production architecture
   limitations；不阻塞 freeze，后续测试基础设施打磨项）：
   1) 重装后 udev 服务偶发卡死（shepherd "Starting service udev..." 挂起，
      btrfs-control 已存在警告）——基础设施问题，产品代码已另行完整验证
   2) 密码回退路径 Argon2 验证在 QEMU 下极慢（luksAddKey ~5 分钟边缘）
   3) swtpm 状态写回依赖正常退出（pkill 写回偶发不完整——已加退出等待）


---

## 最终产品架构（Final Architecture）

```
Virelith
  ├─ tpm2-tss 4.2.0
  └─ tpm2-tools 5.8
            ↓
Guix initrd
  Guile PID1（Guix 原生 initrd 模型）
     ↓
  boot/device resolver
     ├─ LUKS UUID → exact system partition
     └─ sibling ESP
     ↓
  TPM PCR7 unlock
     ↓
  spawn / posix_spawn
     ↓
  tpm2_unseal
     │
     │ pipe（stdout fd → stdin fd）
     ▼
  cryptsetup
     ↓
  ephemeral root
     ↓
  userspace confirm
     ├─ GC root
     ├─ Recovery promote
     └─ boot-state v2
```

架构中不存在：BusyBox PID1、systemd、PCR11、PolicyAuthorize。
