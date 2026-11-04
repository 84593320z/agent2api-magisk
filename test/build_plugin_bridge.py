#!/usr/bin/env python3
"""Build the loader-local ARM64 glibc bridge with Zig 0.13.0.
Usage: python test/build_plugin_bridge.py --zig /path/to/zig
No device operations. Output is the checked-in module/libexec/plugin-spawn.so.
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
ap.add_argument('--zig', required=True)
args = ap.parse_args()
version = subprocess.check_output([args.zig, 'version'], text=True).strip()
assert version == '0.13.0', version
cache = root / '.bridge-build-cache'
cache.mkdir(exist_ok=True)
env = dict(os.environ, TEMP=str(cache), TMP=str(cache), ZIG_GLOBAL_CACHE_DIR=str(cache/'global'), ZIG_LOCAL_CACHE_DIR=str(cache/'local'))
out = root/'module/libexec/plugin-spawn.so'
# Build separately, then read the previous artifact before atomic replacement.
with tempfile.TemporaryDirectory(prefix='out-', dir=cache) as tmp:
    built = Path(tmp)/'plugin-spawn.so'
    subprocess.run([args.zig, 'cc', '-target', 'aarch64-linux-gnu.2.17', '-shared', '-fPIC', '-Os', '-Wall', '-Wextra', '-Werror', str(root/'module/libexec/plugin_spawn.c'), '-o', str(built), '-ldl'], check=True, env=env)
    old = out.read_bytes() if out.exists() else None
    data = built.read_bytes()
    print('old_sha256', hashlib.sha256(old).hexdigest() if old else 'absent')
    print('built_sha256', hashlib.sha256(data).hexdigest())
    print('same_bytes', old == data)
    os.replace(built, out)
