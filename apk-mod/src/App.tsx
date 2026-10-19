import React, { useEffect, useRef } from 'react'
import { store, useStore, bootstrapTheme } from './state/store'
import { TabBar, Toast, AuthGate, ThemeSync } from './components/Shell'
import { PwaNotice } from './components/PwaNotice'
import { usePwa } from './lib/usePwa'
import { HomePage } from './pages/HomePage'
import { ReportPage } from './pages/ReportPage'
import { AccountsPage } from './pages/AccountsPage'
import { AssistantPage } from './pages/AssistantPage'
import { MorePage } from './pages/MorePage'
import { CheckinPage } from './pages/CheckinPage'
import { ModelsPage } from './pages/ModelsPage'
import { KeysPage } from './pages/KeysPage'
import { ProxiesPage } from './pages/ProxiesPage'
import { TasksPage } from './pages/TasksPage'
import { RequestsPage } from './pages/RequestsPage'
import { LogsPage } from './pages/LogsPage'
import { SettingsPage } from './pages/SettingsPage'
import { DocsPage } from './pages/DocsPage'
import { AgentPage } from './pages/AgentPage'
import { ServersPage } from './pages/ServersPage'
import { NavBar } from './components/NavBar'
import { discoverLocalGateways } from './lib/discover'
import { baseLabel } from './lib/servers'
import { t } from './i18n'

/**
 * 路由表。
 *
 * 一级页（`primary: true`）显示底部标签栏；二级页显示返回栏。
 * 与桌面端不同：桌面端 13 个一级菜单在手机上收成 5 个标签，其余进
 * 「更多」的宫格 —— 层级只有两层，不再有第三层。
 */
type ScreenDef = {
  title: string
  component: () => React.ReactElement
  primary?: boolean
}

const SCREENS: Record<string, ScreenDef> = {
  home: { title: t('首页'), component: HomePage, primary: true },
  report: { title: t('报表'), component: ReportPage, primary: true },
  accounts: { title: t('账号'), component: AccountsPage, primary: true },
  assistant: { title: t('AI 助手'), component: AssistantPage, primary: true },
  more: { title: t('更多'), component: MorePage, primary: true },
  checkin: { title: t('签到中心'), component: CheckinPage },
  models: { title: t('模型管理'), component: ModelsPage },
  keys: { title: t('网关 Key'), component: KeysPage },
  proxies: { title: t('网络代理'), component: ProxiesPage },
  tasks: { title: t('定时任务'), component: TasksPage },
  requests: { title: t('请求日志'), component: RequestsPage },
  logs: { title: t('运行日志'), component: LogsPage },
  settings: { title: t('设置'), component: SettingsPage },
  docs: { title: t('接口文档'), component: DocsPage },
  agent: { title: t('Agent 接管'), component: AgentPage },
  servers: { title: t('服务器'), component: ServersPage },
}

export function App() {
  const state = useStore()
  const pwa = usePwa()
  const def = SCREENS[state.route.screen] || SCREENS.home
  const Page = def.component
  const isPrimary = Boolean(def.primary)
  // 助手页要撑满：它自己内部滚动（对话区），外层不能滚
  const fillHeight = state.route.screen === 'assistant'
  /**
   * APK 首次启动、一台服务器都没配：**没有地址就什么都拉不到**，所以直接
   * 顶掉整个界面（不显示标签栏 —— 切到别的标签也是空的）。配好一台之后
   * 这里自然放行。
   */
  const needsServer = state.packaged && !state.server

  useEffect(() => {
    bootstrapTheme()
    store.restoreFromHash()
    // 没有可用服务器时不要发请求：那会以「无法连接网关」的形式刷一屏错误，
    // 而真实原因是「还没填地址」。
    if (!state.packaged || state.server) void store.refresh(true)
    // 浏览器前进 / 后退：hash 变了就跟着走（PWA 里也会触发）
    const onHash = () => store.restoreFromHash()
    window.addEventListener('hashchange', onHash)
    // Android 硬件返回键：Capacitor 会先问 WebView 能不能 goBack，能就 goBack()
    // —— 那一步触发的是 popstate（不是 hashchange 的语义），必须单独接住，
    // 否则内存栈不动，界面会停在旧页面。
    const onPop = () => store.handlePopState()
    window.addEventListener('popstate', onPop)
    return () => {
      window.removeEventListener('hashchange', onHash)
      window.removeEventListener('popstate', onPop)
    }
    // 只在挂载时跑一次：后续的 refresh 由各页面与写操作自己触发
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    // 页面标题跟着当前页走（PWA 里影响任务切换器的显示）
    document.title = needsServer ? `${t('服务器')} · Agent2API` : `${def.title} · Agent2API`
  }, [def.title, needsServer])

  /**
   * APK 首次启动：自动发现本机网关。
   *
   * 网关就跑在同一台手机的 Magisk 模块里，用户没有「IP」这个概念 —— 让他手填
   * `127.0.0.1:3065` 等于把内部实现甩给用户。这里在环回地址上并发探一遍
   * （默认端口优先，1.2 秒内出结果），探到就直接建好服务器条目并拉会话。
   *
   * 只在「打包形态 + 一台都没配」时跑：已经配过的不要覆盖用户的选择，
   * 探不到也不报错（照常落到手填页面，那是离线/端口被改时的正常路径）。
   */
  const autoDiscover = useRef(false)
  useEffect(() => {
    if (!state.packaged || state.server || autoDiscover.current) return
    autoDiscover.current = true
    let cancelled = false
    void (async () => {
      const found = await discoverLocalGateways()
      if (cancelled || found.length === 0) return
      const existing = new Set(store.get().servers.map(item => item.base))
      let firstId = ''
      for (const item of found) {
        if (existing.has(item.base)) continue
        const id = store.addServer({ name: t('本机网关'), base: item.base })
        if (!firstId) firstId = id
      }
      if (firstId) store.switchServer(firstId)
      store.toast(t('已自动连接本机网关 {addr}', { addr: baseLabel(found[0].base) }))
      void store.refresh(true)
    })()
    return () => {
      cancelled = true
    }
    // 只在「从没配过」这一次触发；配好之后由用户自己切换
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.packaged, state.server])

  if (needsServer) {
    return (
      <div className='m-app'>
        <ThemeSync />
        <div className='m-scroll' data-screen='servers'>
          <ServersPage />
        </div>
        <Toast />
      </div>
    )
  }

  return (
    <div className='m-app' data-offline={pwa.offline ? 'true' : undefined}>
      <ThemeSync />
      <PwaNotice />
      {isPrimary ? null : <NavBar title={def.title} onBack={() => store.back()} />}
      <div
        className='m-scroll'
        style={fillHeight ? { overflow: 'hidden' } : undefined}
        data-screen={state.route.screen}
      >
        <Page />
      </div>
      <TabBar />
      <Toast />
      <AuthGate />
    </div>
  )
}
