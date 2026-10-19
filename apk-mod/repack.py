#!/usr/bin/env python3
"""把重新构建的 Web 产物打进官方 APK，并保留原有的压缩方式。

为什么用 Python 重写 zip 而不是 gradle 重编：
  · 本次改动全在 `assets/public/`（Capacitor 的 Web 根），原生层一行没动；
  · 重编需要完整 Android SDK + AGP + 网络拉依赖，改一行 JS 却要几分钟；
  · zip 重写能把「哪些条目必须 STORED」这种细节钉死（resources.arsc 必须
    STORED，否则 Android 11+ 装不上 —— 这是最常见的自打包翻车点）。

旧签名（META-INF/*.RSA|*.SF|*.MF）必须删掉：留着它们 apksigner 会拒绝，
或者签出「双签名」的坏包。
"""
import os
import sys
import zipfile

ORIG = r"E:\AI\work\agent2api\apk\Agent2API-3.1.0.apk"
WEB = r"E:\AI\tmp\a2a-src\desktop-tauri\mobile\android-www"
OUT = r"E:\AI\work\agent2api\apk\Agent2API-3.1.2-mod-unsigned.apk"

# 原包里这几个 0 字节占位是 Capacitor 的 cordova 兼容层产物，构建产物里没有，
# 原样带上，免得哪天 WebView 侧真去 require 它们
EXTRA = ["cordova.js", "cordova_plugins.js"]

SIG_SUFFIX = (".RSA", ".SF", ".MF", ".DSA", ".EC")
WEB_PREFIX = "assets/public/"


def main():
    if not os.path.isdir(WEB):
        print("找不到构建产物：", WEB)
        return 1
    src = zipfile.ZipFile(ORIG)
    kept = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as dst:
        for info in src.infolist():
            name = info.filename
            if name.startswith(WEB_PREFIX):
                continue
            if name.startswith("META-INF/") and name.upper().endswith(SIG_SUFFIX):
                continue
            data = src.read(name)
            out = zipfile.ZipInfo(name, date_time=info.date_time)
            out.compress_type = info.compress_type  # 关键：resources.arsc 保持 STORED
            out.external_attr = info.external_attr
            out.create_system = info.create_system
            dst.writestr(out, data)
            kept += 1

        added = 0
        for root, dirs, files in os.walk(WEB):
            dirs.sort()
            for f in sorted(files):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, WEB).replace("\\", "/")
                with open(full, "rb") as fh:
                    data = fh.read()
                out = zipfile.ZipInfo(WEB_PREFIX + rel, date_time=(2026, 10, 19, 0, 0, 0))
                out.compress_type = zipfile.ZIP_DEFLATED
                out.external_attr = 0o100644 << 16
                out.create_system = 3
                dst.writestr(out, data)
                added += 1

        # 原包里那两个 0 字节 cordova 占位
        for name in EXTRA:
            try:
                data = src.read(WEB_PREFIX + name)
            except KeyError:
                continue
            out = zipfile.ZipInfo(WEB_PREFIX + name, date_time=(2026, 10, 19, 0, 0, 0))
            out.compress_type = zipfile.ZIP_DEFLATED
            out.external_attr = 0o100644 << 16
            out.create_system = 3
            dst.writestr(out, data)
            added += 1

    src.close()
    print("OK %s" % OUT)
    print("   保留 %d 条 / 新增 %d 条 / %.2f MB" % (kept, added, os.path.getsize(OUT) / 1048576))
    return 0


if __name__ == "__main__":
    sys.exit(main())
