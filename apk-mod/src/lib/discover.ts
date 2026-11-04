/**
 * 本机网关自动发现。
 *
 * ── 为什么需要它 ──────────────────────────────────────────────
 * APK 的界面打在包里，页面 origin 是 `https://localhost`，与网关**必然跨源**，
 * 所以地址只能手填。可当网关就跑在同一台手机上（Magisk 模块 chroot 里那个
 * agent2api-server）时，用户手上根本没有「IP」这个概念 —— 让他去填
 * `127.0.0.1:3065` 属于把内部实现泄露给用户。
 *
 * ── 为什么是端口扫描而不是读文件 ──────────────────────────────
 * 模块的配置在 `/data/adb/agent2api/env.sh`，普通应用读不到（SELinux +
 * 权限双重限制），WebView 更读不到。所以只能「试」：环回地址上挨个打
 * `/health`，用响应体特征确认是不是本家网关。
 *
 * ── 为什么只扫环回 ────────────────────────────────────────────
 * 扫局域网网段（192.168.x.1-254）会产生 254 次探测，既慢又容易被系统判成
 * 端口扫描；而且「模块 + APK 在同一台手机」才是要解决的场景，局域网直连
 * 仍然走手填。
 *
 * ── 为什么要看响应体而不是只看 200 ────────────────────────────
 * 3065 是常用端口，别的服务也可能在那儿返回 200（甚至是任意 JSON）。
 * 这里用**两段判据**，任一段命中即认：
 *
 *   1. `/health` 是完整摘要（桌面形态）：带 `transport` / `authRequired` /
 *      `upstreamConfigured` / `defaultModel` 这些本家字段。
 *   2. `/health` 只有 `{"status":"ok"}`（headless 形态，见下）+ 
 *      `/api/panel/status` 回 `{registered:boolean}` 的信封。
 *
 * 第 2 段是 3.1.2 版在真机上踩过的坑：模块跑的 headless 服务会把面板闸门
 * 打开（`access::panel_gate()`），这时 `/health` **只回答进程活着**，整份
 * 摘要不外泄（见 server/api/health.rs 的注释）。只认第 1 段的实现在手机上
 * 永远探不到自家网关。`/api/panel/status` 挂在 public 路由上（登录页要先问
 * 「注册过没有」），刚好可以当第二指纹——它的响应形状是本家独有的信封
 * `{success:true,data:{registered:bool}}`。
 *
 * 两段都只看**形状**，不要求管理员已注册：没注册的网关同样要能被发现。
 */

import { normalizeBase } from './servers'

/** 默认端口排在最前，其余按就近顺序扫（用户改端口时多数落在这一段） */
const PORTS: number[] = [3065, ...range(3060, 3080).filter(port => port !== 3065)]

function range(from: number, to: number): number[] {
  const list: number[] = []
  for (let port = from; port <= to; port += 1) list.push(port)
  return list
}

export type Found = {
  /** 归一化后的基地址，形如 http://127.0.0.1:3065 */
  base: string
  /** 网关版本（`/health` 里有就带上，用于列表展示） */
  version?: string
}

/** 带超时的 GET + JSON；任何异常都归一成 null */
async function getJson(url: string, timeoutMs: number): Promise<Record<string, unknown> | null> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      cache: 'no-store',
      headers: { Accept: 'application/json' },
    })
    if (!response.ok) return null
    const body: unknown = await response.json().catch(() => null)
    return body && typeof body === 'object' ? (body as Record<string, unknown>) : null
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}

/** 第 1 段：完整摘要形态的 `/health` */
function hasHealthMarker(body: Record<string, unknown> | null): boolean {
  if (!body) return false
  if (typeof body.status !== 'string') return false
  return (
    'transport' in body ||
    'authRequired' in body ||
    'upstreamConfigured' in body ||
    'defaultModel' in body ||
    'chatApiUrl' in body ||
    'authApiBase' in body
  )
}

/** 第 2 段：headless 形态下的面板指纹（`{success,data:{registered}}` 信封） */
function hasPanelMarker(body: Record<string, unknown> | null): boolean {
  if (!body) return false
  const data = body.data
  if (data && typeof data === 'object' && typeof (data as Record<string, unknown>).registered === 'boolean') {
    return true
  }
  return typeof body.registered === 'boolean'
}

/** 单个候选的探测：超时、非 200、非 JSON、特征不符都算「不是」 */
async function probeCandidate(base: string, timeoutMs: number): Promise<Found | null> {
  const health = await getJson(`${base}/health`, timeoutMs)
  if (hasHealthMarker(health)) {
    const version = typeof health?.version === 'string' ? health.version : undefined
    return { base, ...(version ? { version } : {}) }
  }
  // headless：/health 只有 {"status":"ok"}，再问一次面板指纹
  const panel = await getJson(`${base}/api/panel/status`, timeoutMs)
  if (hasPanelMarker(panel)) return { base }
  return null
}

/**
 * 扫环回地址找网关。
 *
 * 21 个候选**并发**探测，每个 1.2 秒超时 —— 最坏 1.2 秒出结果（不是 21 × 1.2）。
 * 环回连接要么立刻拒绝（毫秒级），要么立刻成功，长超时只用来兜住
 * 「端口被防火墙 DROP」这种极端情况。headless 形态的候选会多打一次
 * `/api/panel/status`，仍然是并发且共用同一组超时。
 */
export async function discoverLocalGateways(timeoutMs = 1200): Promise<Found[]> {
  const candidates = PORTS.map(port => normalizeBase(`127.0.0.1:${port}`)).filter(Boolean)
  const results = await Promise.all(candidates.map(base => probeCandidate(base, timeoutMs)))
  const found: Found[] = []
  const seen = new Set<string>()
  for (const item of results) {
    if (!item || seen.has(item.base)) continue
    seen.add(item.base)
    found.push(item)
  }
  // 默认端口优先展示
  found.sort((a, b) => {
    const portA = Number(a.base.split(':').pop())
    const portB = Number(b.base.split(':').pop())
    return portA - portB
  })
  return found
}
