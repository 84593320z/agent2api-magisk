#!/usr/bin/env python3
"""把重新构建的 Web 产物打进官方 APK，并保留原有的压缩方式。

为什么用 Python 重写 zip 而不是 gradle 重编：
  · 本次改动全在 `assets/public/`（Capacitor 的 Web 根），原生层一行没动；
  · 重编需要完整 Android SDK + AGP + 网络拉依赖，改一行 JS 却要几分钟；
  · zip 重写能把「哪些条目必须 STORED」这种细节钉死（resources.arsc 必须
    STORED，否则 Android 11+ 装不上 —— 这是最常见的自打包翻车点）。

旧签名（META-INF/*.RSA|*.SF|*.MF）必须删掉：留着它们 apksigner 会拒绝，
或者签出「双签名」的坏包。

用法（无参数时打印用法并退出 1）：
  python repack.py \\
    --apk   /path/to/Agent2API-3.1.0.apk \\
    --web   /path/to/desktop-tauri/mobile/android-www \\
    --out   /path/to/Agent2API-3.1.2-mod-unsigned.apk \\
    [--apk-sha256 <原 APK 的 sha256，可选>]

输出是「先写临时文件、读回校验、最后原子替换」：打包中途失败不会把上一次
可用的输出包截成半截，也不会覆盖到原 APK 上。

签名不在本脚本职责内：用 apksigner + 你自己的 keystore（见 README-mod.md
「签名」一节）。原仓库曾把 keystore 与口令一起提交进 git，那个 key 必须
视为已泄露，请务必换新。
"""
import argparse
import hashlib
import os
import sys
import zipfile

# 原包里这几个 0 字节占位是 Capacitor 的 cordova 兼容层产物，构建产物里没有，
# 原样带上，免得哪天 WebView 侧真去 require 它们
EXTRA = ["cordova.js", "cordova_plugins.js"]

SIG_SUFFIX = (".RSA", ".SF", ".MF", ".DSA", ".EC")
WEB_PREFIX = "assets/public/"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def same_file(a: str, b: str) -> bool:
    """判断两个路径是否指向同一个文件。

    只用字符串或 abspath 比较是不够的：`out.apk` 与 `OUT.APK`（Windows /
    macOS 大小写不敏感文件系统）、以及硬链接，abspath 都不同名却指向同一
    inode；一旦当成两个文件，`open(out, "w")` 会在读源包之前就把它截成 0
    字节，整个包直接报废（RR-10）。
    """
    try:
        if os.path.exists(a) and os.path.exists(b) and os.path.samefile(a, b):
            return True
    except OSError:
        pass
    na = os.path.normcase(os.path.realpath(a))
    nb = os.path.normcase(os.path.realpath(b))
    return na == nb


def inside(child: str, parent: str) -> bool:
    c = os.path.normcase(os.path.realpath(child))
    p = os.path.normcase(os.path.realpath(parent))
    return c == p or c.startswith(p + os.sep)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="把重新构建的 Web 产物塞回官方 APK（不签名）",
    )
    parser.add_argument("--apk", required=True, help="官方原版 APK 路径")
    parser.add_argument("--web", required=True, help="Web 构建产物目录（含 index.html）")
    parser.add_argument("--out", required=True, help="输出 APK 路径（未签名）")
    parser.add_argument(
        "--apk-sha256",
        default=None,
        help="原 APK 期望的 sha256（可选；给了就校验，防止拿错基线包）",
    )
    return parser.parse_args()


def build(apk: str, web: str, out: str) -> tuple:
    """把包写到 out（调用方保证 out 不是源包）。返回 (保留条数, 新增条数)。"""
    kept = 0
    added = 0
    with zipfile.ZipFile(apk) as src, zipfile.ZipFile(
        out, "w", zipfile.ZIP_DEFLATED, compresslevel=6
    ) as dst:
        for info in src.infolist():
            name = info.filename
            if name.startswith(WEB_PREFIX):
                continue
            if name.startswith("META-INF/") and name.upper().endswith(SIG_SUFFIX):
                continue
            data = src.read(name)
            dstinfo = zipfile.ZipInfo(name, date_time=info.date_time)
            dstinfo.compress_type = info.compress_type  # 关键：resources.arsc 保持 STORED
            dstinfo.external_attr = info.external_attr
            dstinfo.create_system = info.create_system
            dst.writestr(dstinfo, data)
            kept += 1

        for root, dirs, files in os.walk(web):
            dirs.sort()
            for f in sorted(files):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, web).replace("\\", "/")
                with open(full, "rb") as fh:
                    data = fh.read()
                dstinfo = zipfile.ZipInfo(
                    WEB_PREFIX + rel, date_time=(2026, 10, 19, 0, 0, 0)
                )
                dstinfo.compress_type = zipfile.ZIP_DEFLATED
                dstinfo.external_attr = 0o100644 << 16
                dstinfo.create_system = 3
                dst.writestr(dstinfo, data)
                added += 1

        # 原包里那两个 0 字节 cordova 占位
        for name in EXTRA:
            try:
                data = src.read(WEB_PREFIX + name)
            except KeyError:
                continue
            dstinfo = zipfile.ZipInfo(
                WEB_PREFIX + name, date_time=(2026, 10, 19, 0, 0, 0)
            )
            dstinfo.compress_type = zipfile.ZIP_DEFLATED
            dstinfo.external_attr = 0o100644 << 16
            dstinfo.create_system = 3
            dst.writestr(dstinfo, data)
            added += 1
    return kept, added


def verify(path: str, expect_entries: int) -> None:
    """读回输出包：中央目录完整、每条 CRC 可校验、条目数对得上。"""
    with zipfile.ZipFile(path) as chk:
        bad = chk.testzip()
        if bad is not None:
            raise RuntimeError("输出包 CRC 校验失败：%s" % bad)
        got = len(chk.infolist())
    if got != expect_entries:
        raise RuntimeError(
            "输出包条目数不符：期望 %d 实际 %d" % (expect_entries, got)
        )


def main() -> int:
    args = parse_args()
    if not os.path.isfile(args.apk):
        print("找不到原 APK：", args.apk, file=sys.stderr)
        return 1
    if not os.path.isdir(args.web):
        print("找不到构建产物：", args.web, file=sys.stderr)
        return 1
    if not os.path.isfile(os.path.join(args.web, "index.html")):
        print("构建产物里没有 index.html，怀疑传错目录：", args.web, file=sys.stderr)
        return 1
    if same_file(args.apk, args.out):
        print(
            "--out 与 --apk 是同一个文件（大小写别名/硬链接也算），"
            "读包前会把源文件截断：%s" % args.out,
            file=sys.stderr,
        )
        return 1
    if inside(args.out, args.web):
        print(
            "--out 不能放在 --web 目录里：输出包会被当成网页资源再打进去",
            file=sys.stderr,
        )
        return 1

    if args.apk_sha256:
        got = sha256_file(args.apk)
        if got != args.apk_sha256.lower():
            print(
                "原 APK sha256 不符：want=%s got=%s" % (args.apk_sha256.lower(), got),
                file=sys.stderr,
            )
            return 1
        print("原 APK sha256 校验通过：%s" % got)

    out_abs = os.path.abspath(args.out)
    out_dir = os.path.dirname(out_abs)
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    # 先写同目录临时文件，校验通过才原子替换；失败时旧输出原样保留（RR-11）。
    tmp_out = "%s.tmp.%d" % (out_abs, os.getpid())
    try:
        kept, added = build(args.apk, args.web, tmp_out)
        verify(tmp_out, kept + added)
        os.replace(tmp_out, out_abs)
    except Exception as exc:  # noqa: BLE001 - 任何失败都要保住旧输出
        try:
            if os.path.exists(tmp_out):
                os.unlink(tmp_out)
        except OSError:
            pass
        print("打包失败，未覆盖原有输出：%s" % exc, file=sys.stderr)
        return 1

    print("OK %s" % args.out)
    print(
        "   保留 %d 条 / 新增 %d 条 / %.2f MB"
        % (kept, added, os.path.getsize(out_abs) / 1048576)
    )
    print("   输出未签名；用 apksigner + 你自己的 keystore 签名后再安装")
    return 0


if __name__ == "__main__":
    sys.exit(main())
