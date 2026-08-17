#!/usr/bin/env python3
# T7 串口交互驱动 v2：QEMU -serial pty + 真实 PTY 交互。
# 用法: tools/t7-interact.py <qemu-args...>  （qemu 参数需含 -serial pty）
# 交互脚本（env T7_SCRIPT="wait:...|send:...|..."）：
#   wait:<pattern>   等待串口输出出现（基于 prompt 的状态机，无猜 sleep）
#   send:<text>      发送一行（\r 结尾，终端行规约）
#   raw:<text>       发送原始字节
#   cmd:<command>    发送命令
#   expect:<pattern> 断言输出出现
#   sleep:<n>        显式等待（仅收尾用）
#   mark:<name>      保存当前输出快照到 /tmp/t7-snapshot-<name>.log
import os, re, select, subprocess, sys, time, termios

script = os.environ.get("T7_SCRIPT", "wait:Enter passphrase|send:t7-recovery-password|wait:root@guix-vm")
steps = [s.split(":", 1) for s in script.split("|")]

# 串口后端：优先用 QEMU unix socket chardev（@SOCK@）——纯字节流，
# 无 pty termios 干扰（QEMU pty 后端的输入路径实测不可靠：密码送达
# 后 cryptsetup 无响应）。@PTY@ 走 QEMU 自建 pty（从 stderr 解析路径）。
import re
args = [os.environ.get("QEMU_BIN", "qemu-system-x86_64")]
sock_path = os.environ.get("T7_SOCK", "/tmp/t7-serial.sock")
fd = None
serial_mode = None
master = slave = None
if "@PTYFILE@" in sys.argv[1:]:
    import pty as _pty
    master, slave = _pty.openpty()
    slave_name = os.ttyname(slave)
    print(f"[t7] PTY slave: {slave_name}", flush=True)
out_args = []
for a in sys.argv[1:]:
    if a == "@SOCK@":
        serial_mode = "socket"
        out_args += ["-chardev", f"socket,id=serial0,path={sock_path},server=on,wait=off",
                     "-serial", "chardev:serial0"]
    elif a == "@PTY@":
        serial_mode = "pty"
        out_args += ["pty"]
    elif a == "@PTYFILE@":
        # python 自建 PTY，把 slave 路径作为串口设备传给 QEMU
        # （QEMU 对路径用 file 后端，实测 O_RDWR 双向，r9 验证过）
        serial_mode = "ptyfile"
        out_args.append(slave_name)
    elif a == "@STDIO@":
        # QEMU -serial stdio：python 通过 QEMU stdin/stdout 双向通信
        serial_mode = "stdio"
        out_args += ["stdio"]
    else:
        out_args.append(a)
args += out_args
p = subprocess.Popen(args,
                     stdin=subprocess.PIPE if serial_mode == "stdio" else subprocess.DEVNULL,
                     stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, bufsize=0)
if serial_mode == "ptyfile":
    fd = master
    os.close(slave)  # QEMU 持有 slave 端
elif serial_mode == "stdio":
    fd = p.stdin
    print(f"[t7] serial stdio", flush=True)
if serial_mode == "pty":
    # 从 QEMU stderr 解析 "char device redirected to /dev/pts/N"
    pat = re.compile(rb"char device redirected to (/dev/pts/\d+)")
    stderr_remain = b""
    pty_path = None
    end = time.time() + 60
    while time.time() < end:
        r, _, _ = select.select([p.stderr], [], [], 0.5)
        if r:
            data = os.read(p.stderr.fileno(), 4096)
            if not data:
                break
            stderr_remain += data
            m = pat.search(stderr_remain)
            if m:
                pty_path = m.group(1).decode()
                break
    if not pty_path:
        print(f"[t7] FATAL: QEMU did not report a pty path, stderr: {stderr_remain[:500]!r}", flush=True)
        p.kill()
        sys.exit(1)
    print(f"[t7] QEMU pty: {pty_path}", flush=True)
    fd = os.open(pty_path, os.O_RDWR | os.O_NOCTTY)
    # QEMU 会把 slave 设 raw，但保险起见再关一次 echo
    import fcntl, termios
    attrs = termios.tcgetattr(fd)
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    os.close(p.stderr.fileno())  # 已解析完，剩余 stderr 输出不再需要
elif serial_mode == "socket":
    import socket
    conn = None
    end = time.time() + 60
    while time.time() < end:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(5)
            s.connect(sock_path)
            conn = s
            break
        except OSError:
            time.sleep(0.2)
    if conn is None:
        # 诊断：QEMU 是否还活着、stderr 说了什么
        rc = p.poll()
        err = b""
        try:
            err = os.read(p.stderr.fileno(), 2000)
        except OSError:
            pass
        print(f"[t7] FATAL: cannot connect to {sock_path} (qemu rc={rc}) stderr: {err[:500]!r}", flush=True)
        p.kill()
        sys.exit(1)
    conn.settimeout(0.2)
    fd = conn
    print(f"[t7] serial socket: {sock_path}", flush=True)
print(f"[t7] qemu pid: {p.pid}", flush=True)
buf = b""
log = open(os.environ.get("T7_LOG", "/tmp/t7-interact.log"), "wb")

def tty_write(data):
    """向串口写入：stdio 模式 fd 是文件对象，其余模式是整数 fd。"""
    if serial_mode == "stdio":
        fd.write(data)
        fd.flush()
    else:
        os.write(fd, data)

def pump(timeout=0.2):
    """同时泵取 PTY/socket、QEMU stdout/stderr（防管道阻塞）。"""
    global buf
    sources = [p.stdout, p.stderr]
    if fd is not None and serial_mode != "stdio":
        sources.insert(0, fd)
    r, _, _ = select.select(sources, [], [], timeout)
    got = False
    for src in r:
        try:
            data = os.read(src.fileno(), 4096)
        except (OSError, ValueError):
            data = b""
        if data:
            buf += data
            log.write(data)   # 实时落盘：脚本被杀也不丢串口日志
            log.flush()
            got = True
    return got

def wait_for(pattern, timeout=300):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        if pattern in buf.decode("utf-8", "replace"):
            return True
        pump(0.2)
    return False

for kind, arg in steps:
    if kind == "wait":
        print(f"[t7] wait: {arg}", flush=True)
        if not wait_for(arg):
            print(f"[t7] TIMEOUT: {arg}", flush=True)
            break
    elif kind == "send":
        print(f"[t7] send: {arg}", flush=True)
        # cryptsetup 交互读密码的 termios 下 \r 不触发行提交；
        # \n 是行结束符（fifo/stdio 验证过的成功方式）
        tty_write(arg.encode() + b"\n")
        time.sleep(0.5)
    elif kind == "raw":
        tty_write(arg.encode())
        time.sleep(0.2)
    elif kind == "cmd":
        print(f"[t7] cmd: {arg}", flush=True)
        # \n 提交（与 send 一致）：\r 在 bash readline 与登录横幅
        # 输出竞争时会丢字符（实测 mount 变 mout）。
        tty_write(b"\n" + arg.encode() + b"\n")
        time.sleep(3)
        pump(0.5)
    elif kind == "expect":
        ok = wait_for(arg, timeout=180)
        print(f"[t7] expect {'OK' if ok else 'FAIL'}: {arg}", flush=True)
        if not ok:
            break
    elif kind == "repl":
        # 向 Guile debug REPL 发送一个表达式，等待提示符再出现。
        # 用于 initrd 崩溃后的挂载/目录诊断（不等待输出内容，
        # 全部进日志，之后用 mark 快照检查）。
        # 实测：一次性写入长表达式会丢字符（~50%），分块慢发。
        print(f"[t7] repl: {arg}", flush=True)
        time.sleep(0.3)
        data = arg.encode()
        for i in range(0, len(data), 16):
            tty_write(data[i:i+16])
            time.sleep(0.05)
        tty_write(b"\n")
        if not wait_for("scheme@(guile-user)", timeout=60):
            print(f"[t7] repl TIMEOUT: {arg}", flush=True)
            break
        pump(0.5)
    elif kind == "mark":
        snap = buf.decode("utf-8", "replace")
        with open(f"/tmp/t7-snapshot-{arg}.log", "w") as f:
            f.write(snap)
        print(f"[t7] mark: {arg} ({len(snap)} chars)", flush=True)
    elif kind == "sleep":
        time.sleep(int(arg))

time.sleep(1)
pump(1)
log.write(buf)
log.close()
if fd is not None and serial_mode != "stdio":
    os.close(fd)
if os.environ.get("T7_KEEP_VM"):
    print(f"[t7] keeping VM alive (pid {p.pid})", flush=True)
else:
    try:
        p.wait(timeout=5)
    except Exception:
        p.kill()
print("[t7] done", flush=True)
