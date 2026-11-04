# -*- coding: utf-8 -*-
"""RR-10 / RR-11 回归：repack.py 的输入保护与输出原子性。

RR-10：`--out` 与原 APK 是同一个文件（大小写别名 / 硬链接）时，旧实现只比
       字符串和 abspath，随后 open(out,'w') 在读源包前把源 APK 截成 0 字节。
RR-11：旧实现直接写最终输出，中途失败会把上一次可用的输出包覆盖成半截；
       现在必须先写临时文件、读回校验、再原子替换。

全部在临时目录内构造合成 APK，不涉及任何真实包。
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPACK = Path(__file__).resolve().parent.parent / 'apk-mod' / 'repack.py'
checks = []


def ck(name, ok, detail=''):
    checks.append((name, bool(ok), detail))


def run(args):
    return subprocess.run(
        [sys.executable, str(REPACK)] + args,
        capture_output=True, text=True, encoding='utf-8', errors='replace',
    )


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def make_apk(path: Path):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('AndroidManifest.xml', b'M' * 64)
        z.writestr('resources.arsc', b'R' * 256, compress_type=zipfile.ZIP_STORED)
        z.writestr('assets/public/index.html', b'OLD')
        z.writestr('assets/public/cordova.js', b'')
        z.writestr('META-INF/CERT.RSA', b'sig')
        z.writestr('META-INF/CERT.SF', b'sig')


def make_web(path: Path):
    path.mkdir(parents=True, exist_ok=True)
    (path / 'index.html').write_text('NEW', encoding='utf-8')
    (path / 'assets').mkdir(exist_ok=True)
    (path / 'assets' / 'app.js').write_text('console.log(1)', encoding='utf-8')


def main() -> int:
    if not REPACK.is_file():
        print('SKIP 缺少 %s' % REPACK)
        return 0
    work = Path(tempfile.mkdtemp(prefix='repack-test-'))
    try:
        apk = work / 'base.apk'
        web = work / 'web'
        make_apk(apk)
        make_web(web)
        base_sha = sha(apk)

        # 1) --out 与 --apk 完全相同
        r = run(['--apk', str(apk), '--web', str(web), '--out', str(apk)])
        ck('out==apk 被拒绝', r.returncode == 1, r.stdout + r.stderr)
        ck('out==apk 没有截断源包', sha(apk) == base_sha)

        # 2) 硬链接别名
        hard = work / 'hard.apk'
        try:
            os.link(apk, hard)
            r = run(['--apk', str(apk), '--web', str(web), '--out', str(hard)])
            ck('硬链接别名被拒绝', r.returncode == 1, r.stdout + r.stderr)
            ck('硬链接别名没有截断源包', sha(apk) == base_sha)
        except OSError:
            print('SKIP 当前文件系统不支持硬链接')

        # 3) 大小写别名（NTFS / APFS 这类大小写不敏感文件系统）
        alias = work / 'BASE.APK'
        if alias.exists() and alias.stat().st_ino == apk.stat().st_ino:
            r = run(['--apk', str(apk), '--web', str(web), '--out', str(alias)])
            ck('大小写别名被拒绝', r.returncode == 1, r.stdout + r.stderr)
            ck('大小写别名没有截断源包', sha(apk) == base_sha)
        else:
            print('SKIP 文件系统大小写敏感')

        # 4) 输出落在 web 目录里（会被当成网页资源再打进去）
        r = run(['--apk', str(apk), '--web', str(web), '--out', str(web / 'out.apk')])
        ck('out 在 web 内被拒绝', r.returncode == 1, r.stdout + r.stderr)
        ck('被拒绝时没有生成输出', not (web / 'out.apk').exists())

        # 5) 正常打包
        out = work / 'out.apk'
        r = run(['--apk', str(apk), '--web', str(web), '--out', str(out)])
        ck('正常打包成功', r.returncode == 0, r.stdout + r.stderr)
        if out.is_file():
            with zipfile.ZipFile(out) as z:
                names = z.namelist()
                ck('网页资源已替换', z.read('assets/public/index.html') == b'NEW')
                ck('新增资源已写入', 'assets/public/assets/app.js' in names)
                arsc = [i for i in z.infolist() if i.filename == 'resources.arsc']
                ck('resources.arsc 仍为 STORED', bool(arsc) and arsc[0].compress_type == 0)
                ck('旧签名条目已删除',
                   not any(n.startswith('META-INF/') and n.upper().endswith(('.RSA', '.SF'))
                           for n in names))
                ck('cordova 占位保留', 'assets/public/cordova.js' in names)
                ck('输出包 CRC 完整', z.testzip() is None)
        ck('没有残留临时文件', not list(work.glob('out.apk.tmp.*')))

        # 6) 失败时保住已有输出
        keep = work / 'keep.apk'
        shutil.copyfile(out, keep)
        keep_sha = sha(keep)
        bad_web = work / 'bad-web'
        bad_web.mkdir()
        r = run(['--apk', str(apk), '--web', str(bad_web), '--out', str(keep)])
        ck('缺少 index.html 时失败', r.returncode == 1, r.stdout + r.stderr)
        ck('失败时旧输出原样保留', sha(keep) == keep_sha)

        # 7) 打包中途失败（构建产物里有个死链），旧输出同样不能被覆盖
        if hasattr(os, 'symlink'):
            link_web = work / 'link-web'
            make_web(link_web)
            try:
                os.symlink(str(work / 'missing-target'), str(link_web / 'dead.bin'))
                before = sha(keep)
                r = run(['--apk', str(apk), '--web', str(link_web), '--out', str(keep)])
                ck('打包中途失败返回 1', r.returncode == 1, r.stdout + r.stderr)
                ck('打包中途失败不覆盖旧输出', sha(keep) == before)
                ck('打包中途失败不留临时文件', not list(work.glob('keep.apk.tmp.*')))
            except OSError:
                print('SKIP 当前环境无法创建符号链接')
        # 8) 原子替换本身失败（输出路径是个目录）：旧现场必须保持，临时文件要清
        dirout = work / 'dirout.apk'
        dirout.mkdir()
        r = run(['--apk', str(apk), '--web', str(web), '--out', str(dirout)])
        ck('输出路径不可替换时失败', r.returncode == 1, r.stdout + r.stderr)
        ck('输出路径仍是目录(未被破坏)', dirout.is_dir())
        ck('替换失败不留临时文件', not list(work.glob('dirout.apk.tmp.*')))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    total = len(checks)
    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, detail in checks:
        print(('  ok   ' if ok else '  FAIL ') + name + ('' if ok else '  ' + detail[:300]))
    print('\n=== %d checked / %d passed / %d failed ===' % (total, passed, total - passed))
    return 0 if passed == total else 1


if __name__ == '__main__':
    sys.exit(main())
