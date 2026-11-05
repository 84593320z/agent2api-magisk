#!/usr/bin/env python3
"""Offline official server/UI sync. Never execute archive members or use a network.

python scripts/autoupdate/server.py --archive release.tar.gz --sha256 HEX \
    --version X.Y.Z --built 2026-11-04T09:17:30Z --module-revision 38 \\
    --commit <40-hex upstream commit> --output evidence

Only seed/{agent2api-server,ui,VERSION} and module.prop are changed. The
description body and seed/VERSION comments plus provenance keys (commit=) are
preserved; only generated fields are rewritten. All archive,
ELF and two reproducible pack.py runs are validated in temporary storage first.
Requires pyelftools (the same dependency as test/inspect_server_elf.py).
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import gzip
import io
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import stat
import tarfile
import tempfile
import zipfile
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[2]
MAX_ARCHIVE = 256 * 1024 * 1024
MAX_MEMBER = 128 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_TAR_STREAM = 272 * 1024 * 1024
MAX_MEMBERS = 10000
EXTRAS = {'install.sh', 'agent2api.service', 'agent2api.env.example'}
FIXED_TIME = (2026, 10, 19, 0, 0, 0)
VERSION_RE = re.compile(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z')


class ValidationError(ValueError):
    """An input failed the closed, offline release validation contract."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular_tree(root):
    """Read and hash every file, rejecting links/reparse points before copying."""
    require(root.is_dir() and not root.is_symlink(), 'source tree is not a real directory')
    files = {}
    for p in sorted(root.rglob('*')):
        s = p.lstat()
        require(not p.is_symlink() and not (getattr(s, 'st_file_attributes', 0) & 0x400),
                'source link/reparse point: ' + p.relative_to(root).as_posix())
        require(stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode), 'special source object')
        if p.is_file():
            files[p.relative_to(root).as_posix()] = digest(p.read_bytes())
    return files


def safe_name(name, is_dir):
    require(isinstance(name, str) and bool(name) and len(name) <= 240, 'invalid member name')
    require(not any(ord(c) < 32 or ord(c) == 127 for c in name), 'control in member name')
    require('\\' not in name and ':' not in name and not name.startswith('/'), 'absolute or Windows path')
    value = name[:-1] if is_dir and name.endswith('/') else name
    parts = value.split('/')
    require(all(p and p not in ('.', '..') and not p.endswith((' ', '.')) for p in parts),
            'noncanonical or traversal member')
    require(all(not re.fullmatch(r'(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?', p)
                for p in parts), 'reserved Windows name')
    require(value in {'agent2api-server', 'ui'} | EXTRAS or value.startswith('ui/'),
            'unknown archive member: ' + value)
    require(not (value == 'agent2api-server' or value in EXTRAS) or not is_dir,
            'expected regular top-level file')
    require(value != 'ui' or is_dir, 'ui must be a directory')
    return value


def read_archive(archive, sha256):
    require(re.fullmatch(r'[0-9a-fA-F]{64}', sha256 or '') is not None, 'sha256 must be 64 hex digits')
    require(archive.is_file() and not archive.is_symlink(), 'archive must be a regular file')
    require(0 < archive.stat().st_size <= MAX_ARCHIVE, 'archive size limit')
    raw = archive.read_bytes()
    require(digest(raw) == sha256.lower(), 'archive sha256 mismatch')
    payload, manifest, names, types = {}, [], set(), {}
    total = 0
    try:
        # Bound the decompressed stream *before* tarfile processes PAX/long-name
        # headers, which otherwise could allocate beyond the member limits.
        if raw.startswith(b'\x1f\x8b'):
            with gzip.GzipFile(fileobj=io.BytesIO(raw)) as gz:
                raw = gz.read(MAX_TAR_STREAM + 1)
        require(len(raw) <= MAX_TAR_STREAM, 'tar stream size limit')
        require(len(raw) >= 1024 and len(raw) % 512 == 0, 'invalid/truncated tar archive')
        with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as tf:
            for i, m in enumerate(tf):
                require(i < MAX_MEMBERS, 'member count limit')
                require(m.isfile() or m.isdir(), 'link/device/special member')
                require(not getattr(m, 'sparse', None), 'sparse member')
                require(not any('sparse' in k.lower() for k in m.pax_headers), 'sparse metadata')
                name = safe_name(m.name, m.isdir())
                require(name.casefold() not in names, 'duplicate/case-colliding member')
                names.add(name.casefold())
                types[name] = 'directory' if m.isdir() else 'file'
                require(0 <= m.size <= MAX_MEMBER, 'member size limit')
                require(not m.isdir() or m.size == 0, 'directory data')
                total += m.size
                require(total <= MAX_TOTAL, 'expanded size limit')
                data = b''
                if m.isfile():
                    stream = tf.extractfile(m)
                    require(stream is not None, 'missing member content')
                    data = stream.read(m.size + 1)
                    require(len(data) == m.size, 'truncated member')
                    if name == 'agent2api-server' or name.startswith('ui/'):
                        payload[name] = data
                manifest.append({'name': name, 'type': types[name], 'size': m.size,
                                 'sha256': digest(data), 'installed': name in payload})
            # Require tar end blocks and only zero padding. Reject concatenated
            # hidden tar streams or garbage after the first logical archive.
            tail = raw[tf.offset:]
            require(len(tail) >= 1024 and not tail.strip(b'\0'), 'invalid tar trailer')
    except (tarfile.TarError, EOFError, OSError) as exc:
        raise ValidationError('invalid/truncated tar archive') from exc
    folded_types = {n.casefold(): typ for n, typ in types.items()}
    for name in types:
        parts = name.casefold().split('/')
        for i in range(1, len(parts)):
            require(folded_types.get('/'.join(parts[:i])) != 'file', 'file/directory prefix collision')
    require(types.get('agent2api-server') == 'file', 'missing top-level server')
    require(types.get('ui') == 'directory', 'missing top-level ui directory')
    require(bool(payload.get('agent2api-server')), 'empty server')
    require(bool(payload.get('ui/index.html')), 'missing or empty ui/index.html')
    return payload, sorted(manifest, key=lambda item: item['name'])


def inspect_elf(path):
    """Parameterized pyelftools inspection derived from test/inspect_server_elf.py."""
    from elftools.elf.elffile import ELFFile
    with path.open('rb') as f:
        e = ELFFile(f)
        require(e['e_machine'] == 'EM_AARCH64' and e.elfclass == 64 and e.little_endian,
                'ELF must be little-endian ARM64: ' + path.name)
        require(e['e_type'] in ('ET_DYN', 'ET_EXEC'), 'ELF must be executable/shared: ' + path.name)
        dynamic = e.get_section_by_name('.dynamic')
        needed = [t.needed for t in dynamic.iter_tags() if t.entry.d_tag == 'DT_NEEDED'] if dynamic else []
        req_sec = e.get_section_by_name('.gnu.version_r')
        required = {v.name: [a.name for a in aux] for v, aux in req_sec.iter_versions()} if req_sec else {}
        def_sec = e.get_section_by_name('.gnu.version_d')
        defined = [a.name for _, aux in def_sec.iter_versions() for a in aux] if def_sec else []
        versions = {}
        if def_sec:
            for v, aux in def_sec.iter_versions():
                versions[v.entry['vd_ndx']] = next(aux).name
        if req_sec:
            for _, aux in req_sec.iter_versions():
                for a in aux:
                    versions[a.entry['vna_other'] & 0x7fff] = a.name
        vs = e.get_section_by_name('.gnu.version')
        symbols = e.get_section_by_name('.dynsym')
        imports, exports = [], []
        if symbols:
            for i, sym in enumerate(symbols.iter_symbols()):
                if not sym.name:
                    continue
                ndx = vs.get_symbol(i).entry['ndx'] if vs else 1
                version = versions.get(ndx & 0x7fff) if isinstance(ndx, int) else None
                item = [sym.name, version]
                if sym['st_shndx'] == 'SHN_UNDEF':
                    if sym['st_info']['bind'] != 'STB_WEAK':
                        imports.append(item)
                elif sym['st_info']['bind'] in ('STB_GLOBAL', 'STB_WEAK', 'STB_GNU_UNIQUE') and sym['st_other']['visibility'] in ('STV_DEFAULT', 'STV_PROTECTED'):
                    exports.append(item)
        interp = [s.get_interp_name() for s in e.iter_segments() if s['p_type'] == 'PT_INTERP']
    return {'sha256': digest(path.read_bytes()), 'machine': 'EM_AARCH64', 'interpreter': interp,
            'needed': needed, 'required_versions': required, 'defined_versions': defined,
            'imports': imports, 'exports': exports}


def elf_report(server, libdir, version):
    raw = server.read_bytes()
    versions = sorted(set(v.decode('ascii') for v in re.findall(rb'agent2api/[0-9][0-9A-Za-z.+-]*', raw)))
    require(versions == ['agent2api/' + version], 'binary version strings disagree with requested version')
    files = {'agent2api-server': inspect_elf(server)}
    require(files['agent2api-server']['interpreter'] == ['/lib/ld-linux-aarch64.so.1'], 'unexpected ARM64 interpreter')
    for p in sorted(libdir.iterdir()):
        require(p.is_file() and not p.is_symlink(), 'invalid bundled library member')
        files[p.name] = inspect_elf(p)
    require('ld-linux-aarch64.so.1' in files and 'libc.so.6' in files, 'missing loader/libc')
    libc = (libdir / 'libc.so.6').read_bytes()
    require(libc.count(b'/data/a2a/resolv') == 1 and b'/etc/resolv.conf' not in libc,
            'libc resolver patch missing or changed')
    # Resolve imports only in the transitive DT_NEEDED scope, not unrelated ELF files.
    unresolved = []
    for name, info in files.items():
        scope, pending = {name}, [name]
        while pending:
            current = pending.pop()
            for dep in files[current]['needed']:
                if dep not in files:
                    unresolved.append([current, 'missing library', dep])
                elif dep not in scope:
                    scope.add(dep)
                    pending.append(dep)
        exports = {tuple(s) for n in scope for s in files[n]['exports']}
        export_names = {s[0] for s in exports}
        for dep, required in info['required_versions'].items():
            for ver in required:
                if dep not in scope or ver not in files.get(dep, {}).get('defined_versions', []):
                    unresolved.append([name, 'missing GNU version', dep, ver])
        for sym, ver in info['imports']:
            if (ver and (sym, ver) not in exports) or (not ver and sym not in export_names):
                unresolved.append([name, 'missing strong symbol', sym, ver])
    require(not unresolved, 'ELF closure failure: ' + json.dumps(unresolved[:20]))
    return {'status': 'PASS', 'server_versions': versions, 'unresolved': [], 'files': files,
            'all_needed_libraries_present': True, 'all_required_symbol_versions_present': True,
            'all_strong_imports_resolved': True, 'libc_resolver': '/data/a2a/resolv',
            'verification': 'Offline pyelftools; no archive code or device execution'}


def _description(text, version, revision):
    """Keep the repo's own description text; regenerate only the version-bearing tokens."""
    body = text.strip()
    m = re.match(r'^模块 v\S+ magisk\.[0-9]+｜(.*)$', body)
    if m:
        body = m.group(1).strip()
    require('\n' not in body, 'module description must stay on one line')
    if not body:
        body = '内置 glibc 动态载荷 v%s / 官方 UI；保留现有运行库、shim 与生产脚本。' % version
    # test/verify_fixes.py r18 greps exactly one "载荷 v<binary version>"; keep it in sync.
    body = re.sub(r'载荷 v[0-9]+(?:\.[0-9]+)*', '载荷 v%s' % version, body)
    return '模块 v%s magisk.%d｜%s' % (version, revision, body)


def _rewrite_version(text, updates, order):
    """Rewrite known keys in place, preserving comments and unknown keys such as commit."""
    out, seen = [], set()
    for line in text.splitlines():
        key = line.split('=', 1)[0].strip() if '=' in line and not line.lstrip().startswith('#') else None
        if key in updates:
            if key not in seen:
                out.append('%s=%s' % (key, updates[key]))
                seen.add(key)
            continue
        out.append(line)
    for key in order:
        if key in updates and key not in seen:
            out.append('%s=%s' % (key, updates[key]))
    return '\n'.join(out) + '\n'


def metadata(module, version, built, revision, archive_hash, commit):
    require(VERSION_RE.fullmatch(version) is not None, 'version must be canonical X.Y.Z')
    require(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)', built) is not None,
            'built must be timezone-qualified release ISO timestamp')
    try:
        published = dt.datetime.fromisoformat(built.replace('Z', '+00:00'))
    except ValueError as exc:
        raise ValidationError('invalid release timestamp') from exc
    require(isinstance(revision, int) and 0 < revision <= 99, 'module revision must be 1..99')
    require(isinstance(commit, str) and re.fullmatch(r'[0-9a-f]{40}', commit) is not None,
            'upstream commit must be a lowercase 40-hex SHA')
    prop = (module / 'module.prop').read_text(encoding='utf-8')
    old_ver = re.search(r'^version=v([^ ]+) \(magisk\.([0-9]+)\)$', prop, re.M)
    old_code = re.search(r'^versionCode=([0-9]+)$', prop, re.M)
    require(old_ver is not None and old_code is not None, 'unrecognized current module version metadata')
    require(revision > int(old_ver.group(2)), 'module revision must increase')
    require(VERSION_RE.fullmatch(old_ver.group(1)) is not None and
            tuple(map(int, version.split('.'))) >= tuple(map(int, old_ver.group(1).split('.'))),
            'upstream version rollback')
    datecode = int(published.astimezone(dt.timezone.utc).strftime('%Y%m%d')) * 100 + revision
    require(datecode > int(old_code.group(1)), 'release datecode must increase')
    value = 'v%s (magisk.%d)' % (version, revision)
    prop = re.sub(r'^version=.*$', 'version=' + value, prop, flags=re.M)
    prop = re.sub(r'^versionCode=.*$', 'versionCode=' + str(datecode), prop, flags=re.M)
    described = re.search(r'^description=(.*)$', prop, re.M)
    require(described is not None, 'module description missing')
    prop = re.sub(r'^description=.*$',
                  lambda _m: 'description=' + _description(described.group(1), version, revision),
                  prop, flags=re.M)
    seed_path = module / 'seed/VERSION'
    seed_text = seed_path.read_text(encoding='utf-8') if seed_path.exists() else ''
    updates = {'ver': version, 'built': built, 'arch': 'aarch64',
               'source': 'aimod-cc/Agent2API v%s official release (glibc dynamic; published timestamp)' % version,
               'commit': commit, 'archive_sha256': archive_hash}
    seed_version = _rewrite_version(seed_text, updates,
                                    ('ver', 'built', 'arch', 'source', 'commit', 'archive_sha256'))
    return prop.encode('utf-8'), seed_version.encode('utf-8'), value


def write_payload(module, payload, prop, seed_version):
    ui = module / 'seed/ui'
    # Every old file was read by regular_tree before this controlled replacement.
    if ui.exists():
        require(ui.resolve() == (module / 'seed' / 'ui').absolute(), 'unexpected UI path')
        shutil.rmtree(ui)
    ui.mkdir(parents=True)
    for name, data in sorted(payload.items()):
        target = module / 'seed' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (module / 'seed/VERSION').write_bytes(seed_version)
    (module / 'module.prop').write_bytes(prop)


def verify_zip(path, module, pack):
    expected = {}
    for root, dirs, files in os.walk(module):
        dirs.sort()
        rel = Path(root).relative_to(module).as_posix()
        if rel != '.':
            expected[rel + '/'] = None
        for name in sorted(files):
            if name not in pack['SKIP_NAME'] and not name.endswith(pack['SKIP_SUFFIX']):
                p = Path(root) / name
                expected[p.relative_to(module).as_posix()] = p
    with zipfile.ZipFile(path) as z:
        require(z.testzip() is None, 'ZIP CRC failure')
        require(len(z.namelist()) == len(set(z.namelist())) and set(z.namelist()) == set(expected), 'ZIP member inventory mismatch')
        for item in z.infolist():
            p = expected[item.filename]
            is_dir = p is None
            require(item.date_time == FIXED_TIME, 'ZIP fixed time mismatch')
            require(item.create_system == 3 and item.external_attr >> 16 == pack['mode_for'](item.filename.rstrip('/'), is_dir), 'ZIP UNIX mode mismatch')
            require(z.read(item) == (b'' if is_dir else p.read_bytes()), 'ZIP member bytes mismatch')
    return {'sha256': digest(path.read_bytes()), 'size': path.stat().st_size, 'members': len(expected),
            'crc': 'PASS', 'fixed_time': list(FIXED_TIME), 'unix_modes': 'PASS', 'member_bytes': 'PASS'}


def pack_twice(repo, module, stage, filename):
    pack = runpy.run_path(str(repo / 'pack.py'), run_name='autoupdate_pack')
    require(pack['mode_for']('seed/agent2api-server', False) == 0o100755, 'pack mode contract changed')
    outputs, reports = [], []
    # main.__globals__ is the namespace used by the loaded pack.py functions.
    namespace = pack['main'].__globals__
    for i in (1, 2):
        target = stage / ('pack%d' % i) / filename
        namespace['SRC'], namespace['OUT'] = str(module), str(target)
        with redirect_stdout(io.StringIO()):
            rc = pack['main']()
        require(rc == 0, 'pack.py preflight failed')
        reports.append(verify_zip(target, module, pack))
        outputs.append(target)
    require(outputs[0].read_bytes() == outputs[1].read_bytes(), 'two pack.py runs differ')
    reports[0]['two_runs_identical'] = True
    return outputs[0], reports[0]


def sync(archive, sha256, version, built, module_revision, output, repo=ROOT, commit=None):
    repo, archive, output = Path(repo).resolve(), Path(archive).absolute(), Path(output).absolute()
    module = repo / 'module'
    # Do not permit evidence output to overwrite source or input archive.
    require(output.resolve() != repo and module not in output.resolve().parents and output.resolve() != module,
            'output overlaps module source')
    require(output.resolve() == output and not output.is_symlink(), 'output link/reparse path')
    require(not (output / 'out').is_symlink() and (output / 'out').resolve() == output / 'out',
            'output ZIP directory link/reparse path')
    require(output.resolve() not in archive.resolve().parents, 'archive lies inside output')
    payload, members = read_archive(archive, sha256)
    before = regular_tree(module)
    prop, seed_version, module_version = metadata(module, version, built, module_revision, sha256.lower(), commit)
    with tempfile.TemporaryDirectory(prefix='a2a-server-sync-') as tmp:
        stage = Path(tmp)
        staged_module = stage / 'module'
        shutil.copytree(module, staged_module)
        write_payload(staged_module, payload, prop, seed_version)
        report = elf_report(staged_module / 'seed/agent2api-server', staged_module / 'seed/lib', version)
        filename = 'agent2api-magisk-v%s-magisk.%d-arm64.zip' % (version, module_revision)
        packed, zip_report = pack_twice(repo, staged_module, stage, filename)
        with zipfile.ZipFile(packed) as z:
            for name, data in payload.items():
                require('seed/' + name in z.namelist() and z.read('seed/' + name) == data,
                        'pack.py excluded or changed upstream payload member: ' + name)
        after = regular_tree(staged_module)
        mutable = lambda name: name in ('module.prop', 'seed/VERSION', 'seed/agent2api-server') or name.startswith('seed/ui/')
        stable_before = {n: h for n, h in before.items() if not mutable(n)}
        stable_after = {n: h for n, h in after.items() if not mutable(n)}
        require(stable_before == stable_after, 'stable module files changed during staging')
        require(regular_tree(module) == before, 'source changed concurrently; retry from a clean snapshot')
        manifest = {'status': 'PASS', 'upstream': 'https://github.com/aimod-cc/Agent2API',
                    'version': version, 'built': built, 'commit': commit,
                    'module_version': module_version,
                    'archive_sha256': sha256.lower(), 'archive_members': members,
                    'installed_members': {n: digest(b) for n, b in sorted(payload.items())},
                    'stable_module_files': stable_before,
                    'stable_seed_libraries': {n: h for n, h in before.items() if n.startswith('seed/lib/')},
                    'server_unmodified': True, 'installer_executed': False,
                    'stale_ui_removed': sorted(n for n in before if n.startswith('seed/ui/') and n[5:] not in payload),
                    'zip': dict(zip_report, filename=filename), 'elf_report': 'elf-compatibility.json'}
        # All validation, including pack.py and exact ZIP verification, is complete.
        # Read-before-edit observation above also acts as a concurrent-write guard.
        output.mkdir(parents=True, exist_ok=True)
        (output / 'out').mkdir(exist_ok=True)
        for p in (output / 'out' / filename, output / 'provenance.json', output / 'elf-compatibility.json'):
            require(not p.exists(), 'refusing to overwrite existing output: ' + p.name)
        # Prepare output before editing the source; disk errors leave source untouched.
        shutil.copyfile(packed, output / 'out' / filename)
        for name, data in [('provenance.json', manifest), ('elf-compatibility.json', report)]:
            (output / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        backup = stage / 'original-module'
        shutil.copytree(module, backup)
        try:
            write_payload(module, payload, prop, seed_version)
            require(regular_tree(module) == after, 'post-install source differs from validated stage')
        except BaseException:
            # Restore only our writable subset, never production scripts or libraries.
            original_payload = {'agent2api-server': (backup / 'seed/agent2api-server').read_bytes()}
            original_payload.update({p.relative_to(backup / 'seed').as_posix(): p.read_bytes()
                                     for p in (backup / 'seed/ui').rglob('*') if p.is_file()})
            write_payload(module, original_payload, (backup / 'module.prop').read_bytes(), (backup / 'seed/VERSION').read_bytes())
            raise
    return {'status': 'PASS', 'version': version, 'module_version': module_version,
            'zip': str(output / 'out' / filename), 'sha256': zip_report['sha256'],
            'provenance': str(output / 'provenance.json'), 'elf_report': str(output / 'elf-compatibility.json')}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--built', required=True)
    parser.add_argument('--module-revision', required=True, type=int)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        result = sync(args.archive, args.sha256, args.version, args.built, args.module_revision, args.output,
                      commit=args.commit)
    except (ValidationError, ImportError, OSError, ValueError) as exc:
        parser.exit(1, 'server sync validation failed: %s\n' % exc)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
