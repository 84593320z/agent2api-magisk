import { useCallback, useEffect, useRef, useState } from 'react'
import { Card, Switch } from '@ui'
import { SectionHead } from './ui'
import { t } from '../i18n'
import {
  SWITCH_DEFS,
  fetchSwitches,
  saveSwitch,
  type SwitchDef,
  type SwitchId,
  type SwitchState,
} from '../api/switches'

/**
 * 网关功能开关（APK 专用）。
 *
 * 桌面面板的「设置 → 网关」里有这 9 个开关；手机端原本只能看，改一项要开电脑。
 * 这里把它们搬到手机上，端点与字段和桌面端完全一致（表格在 api/switches.ts）。
 *
 * ── 三条必须守住的规则 ────────────────────────────────────────
 * 1. **读不到就是未知，未知就禁用。** 端点失败时该键从 state 里消失，开关变灰，
 *    绝不用旧值冒充——否则用户看到「已开启」，其实服务端根本没这个状态。
 *    所以每轮回读都是**整份替换**（不是把新值并进旧对象）。
 * 2. **写是串行的。** 同一端点上连点两个开关，后端返回的是整份状态；并发写会让
 *    先发的响应覆盖后发的。这里用一条 promise 链把 PUT 排队。
 * 3. **读不能跨越写屏障。** 写意图入队、写完成（含失败）都推进 epoch，丢弃跨越
 *    任一屏障的旧 GET；pending 隔离在途意图，React 延迟 updater 也要复查代次。
 */
export function GatewaySwitches() {
  const [state, setState] = useState<SwitchState>({})
  const [ready, setReady] = useState(false)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState<Set<SwitchId>>(() => new Set())

  /** 在途写入：id → 目标值。回读时盖住这些键 */
  const pending = useRef<Map<SwitchId, boolean>>(new Map())
  /** 读写代次：后发 GET、写入队和写结算都会使旧 GET 作废 */
  const epoch = useRef(0)
  /** 写队列：PUT 串行 */
  const chain = useRef<Promise<void>>(Promise.resolve())
  const alive = useRef(true)

  const load = useCallback(async () => {
    const mine = ++epoch.current
    const next = await fetchSwitches()
    if (!alive.current || mine !== epoch.current) return
    // 整份替换：这一轮没返回的键 = 该端点失败 = 未知（渲染成禁用）
    setState(prev => {
      // React 可以稍后才执行 updater；从 await 到提交之间也可能开始/完成一次写。
      if (!alive.current || mine !== epoch.current) return prev
      const merged: SwitchState = {}
      for (const id of Object.keys(next) as SwitchId[]) merged[id] = next[id]
      for (const [id, value] of pending.current) merged[id] = value
      return merged
    })
    setReady(true)
  }, [])

  useEffect(() => {
    alive.current = true
    void load().catch(() => {
      if (alive.current) setError(t('读取网关开关失败，稍后自动重试'))
    })
    const timer = window.setInterval(() => {
      // 页面在后台时不必打扰网关；回到前台由 visibilitychange 立刻补一次
      if (document.visibilityState === 'hidden') return
      void load().catch(() => {})
    }, 5000)
    const onVisible = () => {
      if (document.visibilityState === 'visible') void load().catch(() => {})
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      alive.current = false
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [load])

  const toggle = (id: SwitchId, next: boolean) => {
    // 同键重复事件不再排队；不同键仍可进入全局串行队列。
    if (pending.current.has(id)) return
    ++epoch.current
    pending.current.set(id, next)
    setError('')
    setState(prev => ({ ...prev, [id]: next }))
    setBusy(prev => new Set(prev).add(id))
    chain.current = chain.current.then(async () => {
      try {
        const patch = await saveSwitch(id, next)
        if (!alive.current) return
        // 在入队 updater 前固定隔离集合；finally 清 pending 不能改变延迟提交的语义。
        const protectedIds = new Set(pending.current.keys())
        protectedIds.delete(id)
        setState(prev => {
          const merged: SwitchState = { ...prev }
          for (const [key, value] of Object.entries(patch) as [SwitchId, boolean][]) {
            // 当前目标已由 API 严格确认；其余在途键保持各自意图。
            if (!protectedIds.has(key) && (key === id || !pending.current.has(key))) merged[key] = value
          }
          return merged
        })
      } catch {
        if (!alive.current) return
        // 写失败：这个键回到「未知」而不是假装回到旧值——真实状态在服务端，
        // 下一轮回读会拿到；在此之前禁用比显示一个可能是错的开关好。
        setState(prev => {
          const merged: SwitchState = { ...prev }
          delete merged[id]
          return merged
        })
        setError(t('开关保存失败，请检查网关是否可达'))
      } finally {
        // 包含 PUT 在途期间发出的 GET：成功/失败结算后都不能再用其旧快照。
        ++epoch.current
        pending.current.delete(id)
        if (alive.current) {
          setBusy(prev => {
            const copy = new Set(prev)
            copy.delete(id)
            return copy
          })
        }
      }
    })
  }

  const groups: { key: string; title: string; items: SwitchDef[] }[] = [
    { key: 'gateway', title: t('网关行为'), items: SWITCH_DEFS.filter(def => def.group === 'gateway') },
    { key: 'protection', title: t('路由自愈'), items: SWITCH_DEFS.filter(def => def.group === 'protection') },
  ]

  return (
    <>
      {groups.map(group => (
        <div className='m-section' key={group.key}>
          <SectionHead title={group.title} />
          <Card className='m-card'>
            {group.items.map((def, index) => {
              const value = state[def.id]
              const disabled = !ready || value === undefined || busy.size > 0
              return (
                <div
                  key={def.id}
                  className='m-row'
                  style={{
                    alignItems: 'center',
                    gap: 12,
                    padding: '12px 14px',
                    borderTop: index === 0 ? 'none' : '1px solid var(--m-line)',
                  }}
                >
                  <div className='m-grow'>
                    <div className='m-t1'>{t(def.label)}</div>
                    <div className='m-t2' style={{ lineHeight: 1.55 }}>
                      {ready && value === undefined ? t('当前读不到这一项的状态') : t(def.hint)}
                    </div>
                  </div>
                  <Switch
                    checked={value === true}
                    disabled={disabled}
                    size='touch'
                    aria-label={t(def.label)}
                    onCheckedChange={next => toggle(def.id, next === true)}
                  />
                </div>
              )
            })}
          </Card>
          {group.key === 'gateway' && !ready ? (
            <div className='m-t2' style={{ padding: '6px 4px 0' }}>{t('正在读取网关状态…')}</div>
          ) : null}
        </div>
      ))}
      {error ? (
        <div className='m-section' style={{ marginTop: -6 }}>
          <div className='m-t2' style={{ color: 'var(--m-danger)' }}>{error}</div>
        </div>
      ) : null}
    </>
  )
}
