from pathlib import Path
import re, subprocess
root=Path(__file__).resolve().parent
src=(root/'repo/apk-mod/src/pages/SettingsPage.tsx').read_text(encoding='utf-8')
load=re.search(r'const load = useCallback\(async \(silent: boolean\) => \{([\s\S]*?)\n  \}, \[\]\)',src).group(1)
toggle=re.search(r'const toggle = async \(id: SwitchId, next: boolean\) => \{([\s\S]*?)\n  \}\n',src).group(1)
js='''import assert from 'node:assert/strict';
function defer() { let resolve,reject;const p=new Promise((a,b)=>{resolve=a;reject=b}); return {p,resolve,reject}; }
let state={}, busyId=null;const alive={current:true}; const setReady=()=>{};
const setState=x=>{state=typeof x==='function'?x(state):x};const setBusyId=x=>{busyId=x};
const store={toast:()=>{}};const t=x=>x;
let read=defer(), write=defer();
const fetchSwitches=()=>read.p;const saveSwitch=()=>write.p;
'''+f'const load=async(silent)=>{{{load}\n}};\nconst toggle=async(id,next)=>{{{toggle}\n}};\n'+'''
state={debug:false}; const reading=load(true);const writing=toggle('debug',true);
write.resolve({debug:true});await writing;assert.equal(state.debug,true);
read.resolve({debug:false});await reading;assert.equal(state.debug,false);
console.log('CASE1 delayed GET after confirmed PUT: display=false server=true');
// Both writes respond with full /api/routing state; response ordering differs from processing ordering.
state={a:false,b:false};let wa=defer(),wb=defer();
let seq=0;write={get p(){return (++seq===1?wa:wb).p}};
const pa=toggle('a',true);const pb=toggle('b',true);
assert.equal(busyId,'b'); console.log('CASE2 concurrent busyId='+busyId+'; first toggle a is enabled while write a is pending');
wb.resolve({a:true,b:true});await pb;assert.equal(busyId,null);
wa.resolve({a:true,b:false});await pa;assert.equal(state.b,false);
console.log('CASE2 reordered full responses: display.b=false server.b=true');
console.log('2 UI race scenarios reproduced from original load/toggle function bodies');
'''
p=root/'ui-race.mjs';p.write_text(js,encoding='utf-8')
x=subprocess.run(['E:/AI/tools/node/node.exe',str(p)],capture_output=True,text=True,encoding='utf-8')
(root/'ui-race-output.txt').write_text(x.stdout+x.stderr,encoding='utf-8');print(x.stdout+x.stderr);raise SystemExit(x.returncode)
