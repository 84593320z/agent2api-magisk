from pathlib import Path
import hashlib, json, re
from elftools.elf.elffile import ELFFile
R = Path(__file__).resolve().parents[1]
S = R/'upgrade-evidence/server/official-stage'
LIB = R/'module/seed/lib'
def inspect(p):
    with p.open('rb') as f:
        e = ELFFile(f)
        assert e['e_machine'] == 'EM_AARCH64', p
        dyn = e.get_section_by_name('.dynamic')
        needed = [t.needed for t in dyn.iter_tags() if t.entry.d_tag == 'DT_NEEDED'] if dyn else []
        sec = e.get_section_by_name('.gnu.version_r')
        required = {v.name: [a.name for a in aux] for v,aux in sec.iter_versions()} if sec else {}
        sec = e.get_section_by_name('.gnu.version_d')
        defined = [a.name for _,aux in sec.iter_versions() for a in aux] if sec else []
        vs = e.get_section_by_name('.gnu.version')
        names = {}
        sec = e.get_section_by_name('.gnu.version_d')
        if sec:
            for v, aux in sec.iter_versions():
                names[v.entry['vd_ndx']] = next(aux).name
        sec = e.get_section_by_name('.gnu.version_r')
        if sec:
            for v, aux in sec.iter_versions():
                for a in aux: names[a.entry['vna_other'] & 0x7fff] = a.name
        symbols = e.get_section_by_name('.dynsym')
        imports, exports = [], []
        if symbols:
            for i,sym in enumerate(symbols.iter_symbols()):
                if not sym.name: continue
                ndx = vs.get_symbol(i).entry['ndx'] if vs else 1
                version = names.get(ndx & 0x7fff) if isinstance(ndx,int) else None
                item = [sym.name,version]
                if sym['st_shndx'] == 'SHN_UNDEF':
                    if sym['st_info']['bind'] != 'STB_WEAK': imports.append(item)
                else: exports.append(item)
        interp = [seg.get_interp_name() for seg in e.iter_segments() if seg['p_type']=='PT_INTERP']
    return {'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'machine':'EM_AARCH64','interpreter':interp,'needed':needed,'required_versions':required,'defined_versions':defined,'imports':imports,'exports':exports}
allinfo = {'agent2api-server':inspect(S/'agent2api-server')}
for p in sorted(LIB.iterdir()):
    if p.is_file(): allinfo[p.name] = inspect(p)
missing = []
for n,info in allinfo.items():
    for lib in info['needed']:
        if lib not in allinfo: missing.append([n,'missing library',lib])
    for lib,versions in info['required_versions'].items():
        for v in versions:
            if v not in allinfo.get(lib,{}).get('defined_versions',[]): missing.append([n,lib,v])
exports = {tuple(s) for v in allinfo.values() for s in v['exports']}
for n, info in allinfo.items():
    for sym,version in info['imports']:
        if version and (sym,version) not in exports: missing.append([n,'missing versioned symbol',sym,version])
assert not missing, missing
raw = (S/'agent2api-server').read_bytes()
versions = sorted(set(x.decode() for x in re.findall(rb'agent2api/[0-9][0-9A-Za-z.+-]*',raw)))
assert 'agent2api/3.4.1' in versions, versions
assert allinfo['agent2api-server']['interpreter']==['/lib/ld-linux-aarch64.so.1']
assert (LIB/'libc.so.6').read_bytes().count(b'/data/a2a/resolv')==1
assert (LIB/'libc.so.6').read_bytes().count(b'/etc/resolv.conf')==0
report = {'status':'PASS','kind':'official glibc dynamic AArch64','server_versions':versions,'unresolved':missing,'all_needed_libraries_present':True,'all_required_symbol_versions_present':True,'all_versioned_strong_imports_resolved':True,'libc_resolver':'/data/a2a/resolv','files':allinfo,'limitations':['Offline ELF verification; no Android device execution.','Unversioned imports and dynamic dlopen behavior are not runtime-tested.']}
p = R/'upgrade-evidence/server/elf-compatibility.json'
if p.exists(): p.read_bytes()
p.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k!='files'},ensure_ascii=False,indent=2))
print('PASS ELF dependency closure and versioned symbol compatibility:',len(allinfo),'files')
