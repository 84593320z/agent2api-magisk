import assert from 'node:assert/strict';
function defer() { let resolve,reject;const p=new Promise((a,b)=>{resolve=a;reject=b}); return {p,resolve,reject}; }
let state={}, busyId=null;const alive={current:true}; const setReady=()=>{};
const setState=x=>{state=typeof x==='function'?x(state):x};const setBusyId=x=>{busyId=x};
const store={toast:()=>{}};const t=x=>x;
let read=defer(), write=defer();
const fetchSwitches=()=>read.p;const saveSwitch=()=>write.p;
const load=async(silent)=>{
    const next = await fetchSwitches()
    if (!alive.current) return
    setState(next)
    setReady(true)
    if (!silent && Object.keys(next).length === 0) {
      store.toast(t('读取网关开关失败：网关版本可能不支持'), 'err')
    }
};
const toggle=async(id,next)=>{
    const prev = state[id]
    setState(current => ({ ...current, [id]: next }))
    setBusyId(id)
    try {
      const saved = await saveSwitch(id, next)
      if (!alive.current) return
      setState(current => ({ ...current, ...saved }))
      store.toast(next ? t('已开启') : t('已关闭'))
    } catch (error) {
      if (!alive.current) return
      setState(current => ({ ...current, [id]: prev }))
      store.toast(t('保存失败：{message}', { message: error instanceof Error ? error.message : String(error) }), 'err')
    } finally {
      if (alive.current) setBusyId(null)
    }
};

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
