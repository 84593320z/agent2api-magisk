#!/usr/bin/env python3
# 打包 Magisk 模块 zip。
#
# 只做三件事，但每一件都是踩过的坑：
#   1) 权限位写进 zip 的 external_attr（Windows 上 os.chmod 不可靠，必须直接写 zip 头）；
#   2) 换行符必须是 LF —— CRLF 的 shell 脚本在 Android 上会报
#      "/system/bin/sh: xxx: not found"（实际上是 \r 被当成命令名的一部分），
#      是 Windows 打包最常见的致命坑，这里在打包前直接拦下来；
#   3) 时间戳固定，保证同源码打包结果可复现（便于比对 hash）。
import os
import re
import sys
import zipfile

# 相对脚本自身定位，整个目录可以整体搬走（tmp 会被清理，源码树要能独立存活）
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "module")
# 版本号从 module.prop 读，避免「改了版本忘了改打包名」这种低级错
_VER = "v3.1.3"
with open(os.path.join(SRC, "module.prop"), encoding="utf-8") as _fh:
    for _line in _fh:
        if _line.startswith("version="):
            _VER = _line.strip().split("=", 1)[1]
            break
# 版本串形如 "v3.3.0-beta.7 (magisk.32)"：主版本取第一段，再把 magisk.NN 拼上去，这样每次发版的资产文件名不重名，用户也不会下错。
_SLUG = _VER.split()[0]
_m = re.search(r"magisk\.(\d+)", _VER)
if _m:
    _SLUG += "-magisk." + _m.group(1)
OUT = os.path.join(HERE, "dist", "agent2api-magisk-%s-arm64.zip" % _SLUG)

# 必须是 0755 的：安装/运行脚本 + 两个原生可执行文件
EXEC_FILES = {
    "customize.sh", "post-fs-data.sh", "service.sh", "boot-completed.sh",
    "uninstall.sh", "action.sh", "hotinstall.sh",
    "META-INF/com/google/android/update-binary",
    "seed/agent2api-server",
    "seed/lib/ld-linux-aarch64.so.1",
    "tools/curl",
    "tools/a2a",
}

# 这些不该进包（开发产物 / 本机残留）
SKIP_SUFFIX = (".py", ".pyc", ".log", ".zip", ".tmp", ".orig", ".rej", ".bak")
SKIP_NAME = {".DS_Store", "Thumbs.db", "pack.py", "run.sh"}

TEXT_SUFFIX = (".sh", ".prop", ".env", ".md", ".txt", ".json")
TEXT_NAMES = {"ctl", "lib.sh", "module.prop", "default.env"}


def mode_for(rel, is_dir):
    if is_dir:
        return 0o40755
    if rel in EXEC_FILES:
        return 0o100755
    # libexec/ 下全是 shell 库与子命令，必须 0755；tools/ 是随包的可执行文件
    if rel.split("/")[0] in ("libexec", "tools"):
        return 0o100755
    # seed/lib/ 是随包的 glibc 运行时（换回动态载荷时才用得上）
    if rel.startswith("seed/lib/"):
        return 0o100755
    return 0o100644


def is_text(rel):
    base = os.path.basename(rel)
    return rel.endswith(TEXT_SUFFIX) or base in TEXT_NAMES


def main():
    errors = []
    entries = []
    for root, dirs, files in os.walk(SRC):
        dirs.sort()
        rel_dir = os.path.relpath(root, SRC).replace("\\", "/")
        if rel_dir != ".":
            entries.append((rel_dir + "/", None))
        for f in sorted(files):
            if f in SKIP_NAME or f.endswith(SKIP_SUFFIX):
                continue
            full = os.path.join(root, f)
            rel = os.path.relpath(full, SRC).replace("\\", "/")
            if is_text(rel):
                with open(full, "rb") as fh:
                    head = fh.read()
                if b"\r\n" in head:
                    errors.append("CRLF: %s" % rel)
                if b"\x00" in head:
                    errors.append("NUL byte: %s" % rel)
            entries.append((rel, full))

    # 必备文件检查
    must = ["module.prop", "customize.sh", "service.sh", "post-fs-data.sh",
            "uninstall.sh", "action.sh", "boot-completed.sh", "hotinstall.sh",
            "libexec/common.sh", "libexec/dns.sh", "libexec/control.sh",
            "libexec/supervise.sh", "libexec/payload.sh", "libexec/updater.sh",
            "libexec/plugin.sh", "libexec/launch.sh", "libexec/boot-start.sh",
            "libexec/boot-worker.sh", "libexec/hot-restart.sh",
            "libexec/timezone.sh",
            "libexec/a2a", "seed/agent2api-server", "seed/VERSION",
            "tools/curl", "tools/cacert.pem", "settings.conf.example",
            "META-INF/com/google/android/update-binary"]
    have = {e[0] for e in entries}
    for m in must:
        if m not in have:
            errors.append("缺少必备文件: %s" % m)

    if errors:
        print("打包前检查失败：")
        for e in errors:
            print("  -", e)
        return 1

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for rel, full in entries:
            is_dir = full is None
            zi = zipfile.ZipInfo(rel, date_time=(2026, 10, 19, 0, 0, 0))
            zi.create_system = 3                       # UNIX，Magisk 才会读权限位
            zi.external_attr = mode_for(rel.rstrip("/"), is_dir) << 16
            zi.compress_type = zipfile.ZIP_STORED if is_dir else zipfile.ZIP_DEFLATED
            if is_dir:
                z.writestr(zi, b"")
            else:
                with open(full, "rb") as fh:
                    z.writestr(zi, fh.read())

    print("OK  %s" % OUT)
    print("    条目 %d / 体积 %.2f MB" % (len(entries), os.path.getsize(OUT) / 1048576.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
