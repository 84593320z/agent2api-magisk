from pathlib import Path
import zipfile, hashlib, json, struct
root = Path(__file__).resolve().parent
repo, up = root / 'repo', root / 'upstream'
r = {}
zp = next((repo / 'dist').glob('*.zip'))
with zipfile.ZipFile(zp) as z:
    r['pack'] = {
        'filename': zp.name,
        'sha256': hashlib.sha256(zp.read_bytes()).hexdigest(),
        'entries': len(z.infolist()),
        'backslash_entries': [n for n in z.namelist() if chr(92) in n],
        'invalid_mode': [(i.filename, oct(i.external_attr >> 16)) for i in z.infolist() if i.filename.startswith('libexec/') and not i.is_dir() and (i.external_attr >> 16) & 0o111 != 0o111]
    }
b = (repo / 'module/seed/agent2api-server').read_bytes()
endian = '<' if b[5] == 1 else '>'
phoff = struct.unpack_from(endian + 'Q', b, 32)[0]
phsize, num = struct.unpack_from(endian + 'HH', b, 54)
r['payload'] = {
    'sha256': hashlib.sha256(b).hexdigest(), 'size': len(b),
    'elf_class': b[4], 'machine': struct.unpack_from(endian + 'H', b, 18)[0],
    'pt_interp': any(struct.unpack_from(endian + 'I', b, phoff + i * phsize)[0] == 3 for i in range(num)),
    'private_resolv': b.count(b'/data/a2a/resolv'), 'etc_resolv': b.count(b'/etc/resolv.conf')
}
u, s = up / 'desktop-tauri/ui', repo / 'module/seed/ui'
raw, normalized = [], []
for p in s.rglob('*'):
    if not p.is_file():
        continue
    q = u / p.relative_to(s)
    if not q.is_file() or q.read_bytes() != p.read_bytes():
        raw.append(str(p.relative_to(s)))
    if not q.is_file():
        normalized.append(str(p.relative_to(s)))
    elif q.read_bytes() != p.read_bytes():
        try:
            same = q.read_text(encoding='utf-8') == p.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            same = False
        if not same:
            normalized.append(str(p.relative_to(s)))
r['ui_upstream_byte_differences'] = raw
r['ui_upstream_normalized_differences'] = normalized
r['ui_file_count'] = sum(p.is_file() for p in s.rglob('*'))
r['missing_ui_files'] = [str(p.relative_to(u)) for p in u.rglob('*') if p.is_file() and not (s / p.relative_to(u)).is_file()]
text = json.dumps(r, ensure_ascii=False, indent=2)
(root / 'artifact-evidence.json').write_text(text, encoding='utf-8')
print(json.dumps({**r, 'ui_upstream_byte_differences': len(raw)}, ensure_ascii=False, indent=2))
