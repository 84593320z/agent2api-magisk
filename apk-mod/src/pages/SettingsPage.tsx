import { useCallback, useEffect, useRef, useState } from 'react'
import { PageIntro, SectionHead, IconButton } from '../components/ui'
import { Icon } from '../components/Icon'
import { ThemeSwitch } from './MorePage'
import { store, useStore } from '../state/store'
import { locale, localeOptions, setLocale } from '../i18n'
import { storeApiKey } from '../api/client'
import { fetchSwitches, saveSwitch, switchesOf, type SwitchId, type SwitchState } from '../api/switches'
import { usePwa } from '../lib/usePwa'
import { applyUpdate, promptInstall } from '../lib/pwa'
import { apiBase, baseLabel } from '../lib/servers'
import { t } from '../i18n'

/**
 * 设置。
 *
 * ── 手机上只放「改了就生效、且不需要复杂表单」的项 ────────────
 * 桌面端设置页有 11 个分类、几十个字段。手机上保留：
 *   · 外观与语言（纯前端偏好）
 *   · 账号凭证（兼容模式的 API Key、退出登录）
 *   · 网关地址（复制给客户端）
 *   · 关于与安装（PWA 安装引导、版本）
 * 端口、路由、重试、超时、数据保留这些需要看文档才能填对的，一律留在桌面端
 * —— 摆出来只会让人误改。
 */
export function SettingsPage() {
  const { session, packaged, server, servers } = useStore()
  const pwa = usePwa()
  const [installing, setInstalling] = useState(false)
  const currentLocale = locale()
  const options = localeOptions()

  const install = async () => {
    setInstalling(true)
    const outcome = await promptInstall()
    setInstalling(false)
    if (outcome === 'accepted') store.toast(t('正在安装…'))
    else if (outcome === 'dismissed') store.toast(t('已取消安装'))
    // 'unavailable'：没有可用事件（iOS 或已安装），界面本来就展示手动指引
  }

  const signOut = async () => {
    const { logout } = await import('../api/auth')
    const { clearPanelAuth } = await import('../api/client')
    await logout()
    clearPanelAuth()
    store.setAuthLost('login')
    store.toast(t('已退出登录'))
  }

  return (
    <div className='m-page'>
      <PageIntro subtitle={t('外观 · 接入 · 关于')}
        actions={<IconButton name='refresh' label={t('刷新')} onClick={() => void store.refresh(true)} />}
      />

      {/* 服务器：APK 才有（浏览器里地址就是当前 origin，没什么可配的） */}
      {packaged ? (
        <div className='m-section' style={{ marginTop: 0 }}>
          <SectionHead title={t('服务器')} />
          <div className='m-card'>
            <button type='button' className='m-row' onClick={() => store.push('servers')}>
              <span className='m-logo' style={{ background: 'var(--m-primary-soft)', borderColor: 'transparent', color: 'var(--m-primary)' }}>
                <Icon name='server' />
              </span>
              <div className='m-grow'>
                <div className='m-t1'>{server?.name || baseLabel(server?.base || '')}</div>
                <div className='m-t2 m-mono' style={{ fontSize: 11.5 }}>
                  {servers.length > 1 ? t('{n} 台可选 · 点此切换', { n: servers.length }) : baseLabel(server?.base || '')}
                </div>
              </div>
              <span className='m-chev'>
                <Icon name='chev' />
              </span>
            </button>
          </div>
        </div>
      ) : null}

      {/* 网关状态 */}
      <div className='m-section' style={packaged ? undefined : { marginTop: 0 }}>
        <div className='m-card'>
          <div className='m-row'>
            <span
              className='m-logo'
              style={{ background: 'var(--m-ok-soft)', borderColor: 'transparent', color: 'var(--m-ok)' }}
            >
              <Icon name='bolt' />
            </span>
            <div className='m-grow'>
              <div className='m-t1'>{session?.health?.upstreamConfigured ? t('网关运行中') : t('上游未配置')}</div>
              <div className='m-t2 m-mono' style={{ fontSize: 11.5 }}>
                {baseLabel(apiBase())}
              </div>
            </div>
            <span className={`m-badge ${session?.health?.upstreamConfigured ? 'm-badge-ok' : 'm-badge-warn'}`}>
              <i />
              {session?.health?.upstreamConfigured ? t('正常') : t('待配置')}
            </span>
          </div>
        </div>
      </div>

      {/* 网关功能开关：与桌面面板同一份服务端配置，双向同步（见 api/switches.ts） */}
      {session ? <GatewaySwitches /> : null}

      <div className='m-section'>
        <SectionHead title={t('外观')} />
        <div className='m-card'>
          <div className='m-row'>
            <span className='m-logo'>
              <Icon name='moon' />
            </span>
            <div className='m-grow'>
              <div className='m-t1'>{t('主题')}</div>
              <div className='m-t2'>{t('跟随系统 · 浅色 · 深色')}</div>
            </div>
            <ThemeSwitch />
          </div>
          <div className='m-row'>
            <span className='m-logo'>
              <Icon name='globe' />
            </span>
            <div className='m-grow'>
              <div className='m-t1'>{t('界面语言')}</div>
              <div className='m-t2'>{options.find(item => item.code === currentLocale)?.label || currentLocale}</div>
            </div>
            <select
              value={currentLocale}
              onChange={event => setLocale(event.target.value)}
              aria-label={t('界面语言')}
              style={{
                height: 34,
                padding: '0 8px',
                borderRadius: 9,
                border: '1px solid var(--m-line)',
                background: 'var(--m-surface-2)',
                color: 'var(--m-text)',
                // 16px 是 iOS 的阈值：小于它聚焦时 Safari 会自动放大整页
                fontSize: 16,
                flex: 'none',
              }}
            >
              {options.map(item => (
                <option key={item.code} value={item.code}>
                  {item.label}
                </option>
              ))}
            </select>
          </div>
        </div>
      </div>

      <div className='m-section'>
        <SectionHead title={t('接入')} />
        <div className='m-card'>
          <button type='button' className='m-row' onClick={() => store.push('docs')}>
            <span className='m-logo'>
              <Icon name='doc' />
            </span>
            <div className='m-grow'>
              <div className='m-t1'>{t('接口地址')}</div>
              <div className='m-t2 m-mono' style={{ fontSize: 11.5 }}>
                {apiBase()}/v1
              </div>
            </div>
            <span className='m-chev'>
              <Icon name='chev' />
            </span>
          </button>
          <button type='button' className='m-row' onClick={() => store.push('keys')}>
            <span className='m-logo'>
              <Icon name='key' />
            </span>
            <div className='m-grow'>
              <div className='m-t1'>{t('网关 Key')}</div>
              <div className='m-t2'>{t('复制给客户端')}</div>
            </div>
            <span className='m-chev'>
              <Icon name='chev' />
            </span>
          </button>
        </div>
      </div>

      <div className='m-section'>
        <SectionHead title={t('账号')} />
        <div className='m-card'>
          {/* APK 有真正的登录态，给「退出登录」；浏览器端只有 API Key 可清 */}
          {packaged ? (
            <button type='button' className='m-row' onClick={() => void signOut()}>
              <span className='m-logo'>
                <Icon name='logout' />
              </span>
              <div className='m-grow'>
                <div className='m-t1'>{t('退出登录')}</div>
                <div className='m-t2'>{t('退出这台服务器的登录，不影响其他服务器')}</div>
              </div>
              <span className='m-chev'>
                <Icon name='chev' />
              </span>
            </button>
          ) : (
            <button
              type='button'
              className='m-row'
              onClick={() => {
                storeApiKey('')
                store.setAuthLost(null)
                store.toast(t('已清除本机保存的 API Key'))
                void store.refresh(true)
              }}
            >
              <span className='m-logo'>
                <Icon name='logout' />
              </span>
              <div className='m-grow'>
                <div className='m-t1'>{t('清除本机凭证')}</div>
                <div className='m-t2'>{t('只清掉这个浏览器存的 Key，不影响网关')}</div>
              </div>
              <span className='m-chev'>
                <Icon name='chev' />
              </span>
            </button>
          )}
        </div>
      </div>

      {/* APK 不需要装到桌面（本身就是 App），这一段只给浏览器形态 */}
      {packaged ? null : (
      <div className='m-section'>
        <SectionHead title={t('安装到桌面')} />
        <div className='m-card'>
          <div className='m-row'>
            <span className='m-logo'>
              <Icon name='install' />
            </span>
            <div className='m-grow'>
              <div className='m-t1'>{t('当前形态')}</div>
              <div className='m-t2'>
                {pwa.standalone ? t('已作为独立应用运行') : t('浏览器标签页')}
              </div>
            </div>
            <span className={`m-badge ${pwa.standalone ? 'm-badge-ok' : 'm-badge-mute'}`}>
              {pwa.standalone ? t('已安装') : t('未安装')}
            </span>
          </div>

          {pwa.standalone ? (
            <div className='m-card-pad' style={{ borderTop: '1px solid var(--m-line)', fontSize: 12.5, lineHeight: 1.7, color: 'var(--m-text-2)' }}>
              {t('从桌面图标启动，全屏、无地址栏。想卸载：长按图标删除，或清除浏览器站点数据。')}
            </div>
          ) : pwa.canInstall ? (
            <div style={{ borderTop: '1px solid var(--m-line)', padding: '12px 15px 14px' }}>
              <div style={{ fontSize: 12.5, lineHeight: 1.7, color: 'var(--m-text-2)' }}>
                {t('装成 App 后从桌面图标直接进入：全屏打开、没有地址栏。')}
              </div>
              <button
                type='button'
                className='m-btn'
                style={{ marginTop: 10, height: 40 }}
                disabled={installing}
                onClick={() => void install()}
              >
                <Icon name='download' />
                {installing ? t('正在安装…') : t('安装到主屏幕')}
              </button>
            </div>
          ) : (
            <div style={{ borderTop: '1px solid var(--m-line)', padding: '12px 15px 14px' }}>
              <div style={{ fontSize: 12.5, lineHeight: 1.75, color: 'var(--m-text-2)' }}>
                {pwa.showIosHint
                  ? t('Safari 没有安装按钮：点底部的「分享」，选「添加到主屏幕」，再点「添加」。')
                  : t('用浏览器菜单里的「添加到主屏幕」把这一页装成 App：全屏打开、没有地址栏，和原生应用一样。')}
              </div>
              {pwa.showIosHint ? (
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 8,
                    marginTop: 10,
                    padding: '9px 11px',
                    borderRadius: 11,
                    background: 'var(--m-surface-2)',
                    fontSize: 12,
                    color: 'var(--m-text-3)',
                  }}
                >
                  <Icon name='share' style={{ width: 16, height: 16, flex: 'none' }} />
                  <span>{t('分享图标在 Safari 底部工具栏中间')}</span>
                </div>
              ) : null}
            </div>
          )}
        </div>
      </div>
      )}

      {/* 只有真有事时才出现：平时不占版面 */}
      {pwa.updateReady || pwa.swState === 'unsupported' ? (
        <div className='m-section'>
          <SectionHead title={t('应用状态')} />
          <div className='m-card'>
            {pwa.updateReady ? (
              <div className='m-row'>
                <span className='m-logo' style={{ background: 'var(--m-primary-soft)', borderColor: 'transparent', color: 'var(--m-primary)' }}>
                  <Icon name='up' />
                </span>
                <div className='m-grow'>
                  <div className='m-t1'>{t('有新版本')}</div>
                  <div className='m-t2'>{t('重启后生效，不影响当前操作')}</div>
                </div>
                <button type='button' className='m-btn m-sm' onClick={() => void applyUpdate()}>
                  {t('重启更新')}
                </button>
              </div>
            ) : null}
            {pwa.swState === 'unsupported' ? (
              <div className='m-row'>
                <span className='m-logo'>
                  <Icon name='info' />
                </span>
                <div className='m-grow'>
                  <div className='m-t1'>{t('离线缓存未启用')}</div>
                  <div className='m-t2'>{t('浏览器只在 https 或 localhost 下提供离线缓存；局域网 http 访问不影响正常使用')}</div>
                </div>
              </div>
            ) : null}
          </div>
        </div>
      ) : null}

      <div className='m-section' style={{ paddingBottom: 8 }}>
        <div className='m-card'>
          <div className='m-row'>
            <span className='m-logo'>
              <Icon name='info' />
            </span>
            <div className='m-grow'>
              <div className='m-t1'>{t('Agent2API 手机端')}</div>
              <div className='m-t2'>{t('3.1.2-mod · 本机网关自动发现 + 功能开关双向同步')}</div>
            </div>
          </div>
          <div className='m-row' style={{ borderTop: '1px solid var(--m-line)' }}>
            <span className='m-logo'>
              <Icon name='heart' />
            </span>
            <div className='m-grow'>
              <div className='m-t1'>{t('社区与支持')}</div>
              <div className='m-t2'>{t('QQ 群 · Telegram · Discord')}</div>
            </div>
            <span className='m-chev'>
              <Icon name='chev' />
            </span>
          </div>
        </div>
      </div>
    </div>
  )
}


/* ─── 网关功能开关（与桌面面板双向同步）─────────────────────── */

/**
 * 开关行：左侧标题 + 说明，右侧拨动开关。
 *
 * 说明文字常驻（不做 tooltip）：这些开关的名字（「限流垫底」「失败退避」）
 * 不看说明基本猜不出行为，手机上没有 hover 可看，藏起来等于没有。
 */
function SwitchRow({
  label,
  hint,
  checked,
  disabled,
  onChange,
}: {
  label: string
  hint: string
  checked: boolean
  disabled?: boolean
  onChange: (next: boolean) => void
}) {
  return (
    <div className='m-row' style={{ alignItems: 'flex-start' }}>
      <div className='m-grow'>
        <div className='m-t1'>{label}</div>
        <div className='m-t2' style={{ marginTop: 2, lineHeight: 1.55 }}>
          {hint}
        </div>
      </div>
      <button
        type='button'
        role='switch'
        aria-checked={checked}
        aria-label={label}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        style={{
          width: 44,
          height: 26,
          borderRadius: 999,
          border: checked ? '0' : '1px solid var(--m-line-strong)',
          background: checked ? 'var(--m-ok)' : 'var(--m-surface-3)',
          position: 'relative',
          transition: 'background .18s, border-color .18s',
          padding: 0,
          flex: 'none',
          marginTop: 2,
          opacity: disabled ? 0.5 : 1,
        }}
      >
        <span
          style={{
            position: 'absolute',
            top: 3,
            left: checked ? 21 : 3,
            width: 20,
            height: 20,
            borderRadius: '50%',
            background: '#fff',
            boxShadow: '0 1px 3px rgba(0,0,0,.25)',
            transition: 'left .18s cubic-bezier(.3,.9,.4,1)',
          }}
        />
      </button>
    </div>
  )
}

/**
 * 网关功能开关面板。
 *
 * ── 同步策略 ──────────────────────────────────────────────────
 * 没有推送通道，用「短轮询 + 回前台立刻读」：
 *   · 页面可见时每 5 秒回读一次 `/api/*`，面板那边改了这里 5 秒内跟上；
 *   · 从后台切回来立刻读一次（手机最常见的就是「去桌面改了再回来」）；
 *   · 自己拨动是乐观更新 + PUT，失败回滚并 toast，不静默吞掉。
 * 5 秒是权衡：7 个端点并发一次约几十毫秒，耗电可以忽略；再快没有意义
 * （用户不会盯着两个屏同时拨开关）。
 *
 * ── 并发契约（F-009）──────────────────────────────────────────
 * 每个端点的响应体是「整份状态」而非单个字段，乱序到达会互相覆盖：
 *   · 读：全局序号 + 写纪元双校验，过期/乱序/写中响应一律丢弃；
 *   · 写：所有 PUT 走同一条串行队列，按点击顺序执行与合并；
 *   · 任何响应（读/写）落地时跳过仍在队列里的键——它们的真值由
 *     自己那次写的响应带回，落旧快照会把刚拨的开关弹回去；
 *   · 任一写在途时禁用全部开关，页面上不存在可交错的新写。
 */
function GatewaySwitches() {
  const [state, setState] = useState<SwitchState>({})
  const [ready, setReady] = useState(false)
  const [busyIds, setBusyIds] = useState<ReadonlySet<SwitchId>>(new Set())
  const alive = useRef(true)
  /** 读序号：只有最新一次 load 的响应允许落地（丢弃乱序 GET）。 */
  const loadSeq = useRef(0)
  /** 写纪元：任何写开始/结束都 +1；GET 捕获纪元，落地前变了就丢弃。 */
  const epoch = useRef(0)
  /** 写队列尾：所有 PUT 串行执行，响应按队列顺序合并。 */
  const queueTail = useRef<Promise<unknown>>(Promise.resolve())
  /** 仍在队列/在途的乐观更新：id → 目标值。响应合并时跳过这些键。 */
  const pending = useRef(new Map<SwitchId, boolean>())

  const load = useCallback(async (silent: boolean) => {
    const seq = ++loadSeq.current
    const ep = epoch.current
    const next = await fetchSwitches()
    if (!alive.current || seq !== loadSeq.current || ep !== epoch.current) return
    setState(() => {
      // 整份状态以服务端返回为准：没回来的键（端点失败/老网关）必须变成
      // undefined —— 旧实现 `{...current}` 合并会把上一次的已知值留下来，
      // 端点已经 500 了开关还显示可点，拨下去必然失败（RR-08）。
      // 仍在队列里的键由自己的写响应带回，这里保留它的乐观值。
      const merged: SwitchState = {}
      for (const key of Object.keys(next) as SwitchId[]) {
        merged[key] = next[key]
      }
      for (const [key, value] of pending.current) {
        merged[key] = value
      }
      return merged
    })
    setReady(true)
    if (!silent && Object.keys(next).length === 0) {
      store.toast(t('读取网关开关失败：网关版本可能不支持'), 'err')
    }
  }, [])

  useEffect(() => {
    alive.current = true
    void load(false)
    const timer = window.setInterval(() => {
      // 页面不可见时暂停轮询：后台继续打 7 个端点纯属耗电，
      // 回前台本来就有一次立刻读。
      if (document.visibilityState === 'visible') void load(true)
    }, 5000)
    const onVisible = () => {
      if (document.visibilityState === 'visible') void load(true)
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      alive.current = false
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [load])

  const toggle = (id: SwitchId, next: boolean) => {
    const prev = state[id]
    epoch.current += 1
    pending.current.set(id, next)
    setState(current => ({ ...current, [id]: next }))
    setBusyIds(current => new Set(current).add(id))
    queueTail.current = queueTail.current
      .then(async () => {
        try {
          const saved = await saveSwitch(id, next)
          if (!alive.current) return
          epoch.current += 1
          pending.current.delete(id)
          setState(current => {
            const merged: SwitchState = { ...current }
            for (const key of Object.keys(saved) as SwitchId[]) {
              // 跳过仍在队列里的键：这里落的是本次写之前的快照值，
              // 写下去会把后面刚拨的开关弹回去。
              if (pending.current.has(key)) continue
              merged[key] = saved[key]
            }
            return merged
          })
          store.toast(next ? t('已开启') : t('已关闭'))
        } catch (error) {
          if (!alive.current) return
          epoch.current += 1
          pending.current.delete(id)
          setState(current => {
            // 同键还有后续写在排队时不回滚（以最后一次为准）。
            if (pending.current.has(id)) return current
            const rolled: SwitchState = { ...current }
            if (prev === undefined) delete rolled[id]
            else rolled[id] = prev
            return rolled
          })
          store.toast(t('保存失败：{message}', { message: error instanceof Error ? error.message : String(error) }), 'err')
        } finally {
          if (alive.current) {
            setBusyIds(current => {
              const fresh = new Set(current)
              fresh.delete(id)
              return fresh
            })
          }
        }
      })
      // 队列不能因业务失败断链：吞掉异常，让后续写继续排队。
      .catch(() => undefined)
  }

  const renderGroup = (group: 'gateway' | 'protection', title: string) => {
    const defs = switchesOf(group)
    if (defs.length === 0) return null
    return (
      <div className='m-section' style={{ marginTop: 0 }}>
        <SectionHead title={title} />
        <div className='m-card'>
          {defs.map((def, index) => {
            const value = state[def.id]
            return (
              <div key={def.id} style={index === 0 ? undefined : { borderTop: '1px solid var(--m-line)' }}>
                <SwitchRow
                  label={t(def.label)}
                  hint={t(def.hint)}
                  checked={value === true}
                  // 还没读到值（端点失败 / 老网关）就锁住：宁可显示灰的，也不给一个
                  // 拨了没反应的开关 —— 那是最难查的静默失败。
                  // 任一写在途（busyIds 非空）时全部锁住：响应是整份状态，
                  // 允许交错就会互相覆盖（F-009）。
                  disabled={!ready || value === undefined || busyIds.size > 0}
                  onChange={nextValue => void toggle(def.id, nextValue)}
                />
              </div>
            )
          })}
        </div>
      </div>
    )
  }

  return (
    <>
      <div className='m-section'>
        <SectionHead
          title={t('网关功能开关')}
          action={{ label: t('刷新'), onClick: () => void load(false) }}
        />
        <div className='m-card m-card-pad' style={{ fontSize: 11.5, color: 'var(--m-text-3)', lineHeight: 1.7 }}>
          {t('与桌面面板「设置 → 网关」是同一份配置：这边拨了，面板刷新即可看到；面板改了，这边 5 秒内跟上。')}
        </div>
      </div>
      {renderGroup('gateway', t('网关行为'))}
      {renderGroup('protection', t('路由自愈'))}
    </>
  )
}
