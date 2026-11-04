#!/usr/bin/env python3
"""Production-function fault injection; portable shell/file stubs, no Android required."""
from pathlib import Path
import json, os, re, shutil, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('A2A_BOUNDARY_OUT',str(ROOT/'test/out/recovery-boundaries'))).resolve()
OUT.mkdir(parents=True,exist_ok=True)
SH=os.environ.get('A2A_SH') or shutil.which('dash') or shutil.which('sh')
if not SH: raise SystemExit('Missing POSIX shell')
def shellpath(p):
    s=p.as_posix()
    return '/'+s[0].lower()+s[2:] if len(s)>2 and s[1]==':' else s
prefix=(ROOT/'test/txn_test.sh').read_text(encoding='utf8').split('# T0：')[0]
prefix=prefix.replace('SRC=$(cd "$(dirname "$0")/../module" && pwd)', 'SRC="'+shellpath(ROOT/'module')+'"')
prefix=prefix.replace('WORK=${1:-$(dirname "$0")/out/txn}', 'WORK="'+shellpath(OUT)+'"')
cz=(ROOT/'module/customize.sh').read_text(encoding='utf8')
(OUT/'customize-cleanup.sh').write_text(cz[cz.index('install_cleanup() {'):cz.index("trap 'install_cleanup' EXIT")],encoding='utf8',newline='\n')
(OUT/'customize-pre.sh').write_text(cz[cz.index('if svc_is_running; then',cz.index('# 停服：')):cz.index('# ---------------------------------------------------------------------------\n# 3)')],encoding='utf8',newline='\n')
sup=(ROOT/'module/libexec/supervise.sh').read_text(encoding='utf8')
(OUT/'commit.sh').write_text(sup[sup.index('supervise_commit_pending() {'):sup.index('# 启动前准备')],encoding='utf8',newline='\n')
BODY=(ROOT/'test/recovery_boundary_cases.sh').read_text(encoding='utf8')
start=sup.index('if ! payload_recover_interrupted runtime; then')
(OUT/'supervise-gate.sh').write_text('startup_gate() {\n'+sup[start:sup.index('# cgroup 逃逸',start)]+'echo SERVER_START >>"$EVENTS"\n}\n',encoding='utf8',newline='\n')
boot=(ROOT/'module/post-fs-data.sh').read_text(encoding='utf8')
start=boot.index('if ! payload_recover_interrupted boot; then')
(OUT/'boot-gate.sh').write_text(boot[start:boot.index('ensure_layout',start)],encoding='utf8',newline='\n')
expected = {'data-fail': {'rc': '1',
               'data': 'new-schema',
               'journal': 'rollback-failed',
               'running': '0',
               'restart': 'no'},
 'payload-fail': {'rc': '1',
                  'data': 'old-schema',
                  'journal': 'rollback-failed',
                  'running': '0',
                  'restart': 'no'},
 'missing-snapshot': {'rc': '1',
                      'data': 'new-schema',
                      'journal': 'rollback-failed',
                      'running': '0',
                      'restart': 'no'},
 'first-rename': {'injected': '91',
                  'rc': '0',
                  'data': 'old-schema',
                  'journal': ''},
 'signal-data-fail': {'rc': '1',
                      'payload': 'old',
                      'data': 'new-schema',
                      'journal': 'rollback-failed',
                      'running': '0'},
 'signal-payload-fail': {'rc': '1',
                         'payload': 'new',
                         'data': 'old-schema',
                         'journal': 'rollback-failed',
                         'running': '0'},
 'customize-orphan': {'rc': '77', 'continued': '0', 'killed': '1'},
 'customize-recover-fail': {'rc': '77', 'continued': '0', 'running': '0'},
 'customize-stop-fail': {'rc': '77', 'running': '0', 'starts': '0'},
 'commit-unhealthy': {'old': 'yes', 'pending': 'yes'},
 'commit-healthy': {'old': 'no', 'pending': 'no'},
 'snapshot-no-id': {'rc': '1', 'data': 'new-schema'},
 'snapshot-wrong-id': {'rc': '1', 'data': 'new-schema'},
 'second-rename': {'rc': '0', 'data': 'old-schema', 'journal': ''},
 'after-second-rename': {'rc': '0', 'data': 'old-schema', 'journal': ''},
 'restore-rename-fail': {'rc': '1',
                         'data': 'new-schema',
                         'journal': 'rolling-back',
                         'restored': 'yes'},
 'recovered-data-retry': {'rc': '0', 'data': 'old-schema', 'journal': ''},
 'contradictory-data': {'rc': '1',
                        'tmp': 'yes',
                        'aside': 'yes',
                        'data': 'old-schema'},
 'supervisor-recovery-fail': {'rc': '1', 'starts': '0'},
 'boot-recovery-fail': {'rc': '1', 'layout': '0'},
 'customize-safe-fail': {'rc': '77', 'running': '1', 'starts': '1'},
 'first-rename-return-fail': {'first':'1','rc':'0','data':'old-schema','journal':''},
 'payload-rename-retry': {'injected':'91','rc':'0','payload':'old','data':'old-schema','journal':'','marker':'tx-payload-retry','oldpath':'no'},
 'payload-complete-retry': {'injected':'91','rc':'0','payload':'old','data':'old-schema','journal':'','marker':'tx-payload-retry','oldpath':'no'},
 'payload-marker-fail': {'rc':'1','payload':'new','data':'new-schema','journal':'started','oldpath':'yes'}}

(OUT/'probe.sh').write_text(prefix+BODY,encoding='utf8',newline='\n')
results=[]
for name,want in expected.items():
    proc=subprocess.run([SH,shellpath(OUT/'probe.sh'),name],capture_output=True,text=True,encoding='utf8',errors='replace',timeout=90)
    text=proc.stdout+proc.stderr
    (OUT/(name+'.log')).write_text(text,encoding='utf8')
    lines=[x for x in text.splitlines() if x.startswith('RESULT '+name+' ')]
    got=dict(re.findall(r'(\w+)=(\S*)',lines[-1])) if lines else {}
    ok=proc.returncode==0 and all(got.get(k)==v for k,v in want.items())
    results.append({'name':name,'pass':ok,'expected':want,'actual':got,'process_rc':proc.returncode})
    print(('PASS ' if ok else 'FAIL ')+name+' '+json.dumps(got))
(OUT/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf8')
print(f'{sum(x["pass"] for x in results)}/{len(results)} recovery boundaries passed')
raise SystemExit(any(not x['pass'] for x in results))
