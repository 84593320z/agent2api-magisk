/**
 * 本机网关自动发现。
 *
 * ── 为什么需要它 ──────────────────────────────────────────────
 * APK 的界面打在包里，页面 origin 是 `https://localhost`，与网关**必然跨源**，
 * 所以地址只能手填。可当网关就跑在同一台手机的 Magisk/KernelSU 模块里时，
 * 用户手上根本没有「IP」这个概念 —— 让他去填 `127.0.0.1:3065` 属于把内部实现
 * 泄露给用户。
 *
 * ── 为什么是端口扫描而不是读文件 ──────────────────────────────
 * 模块的配置在 `/data/adb/agent2api/env.sh`，普通应用读不到（SELinux + 权限
 * 双重限制），WebView 更读不到。所以只能「试」：环回地址上挨个打探测接口。
 *
 * ── 为什么只扫环回 ────────────────────────────────────────────
 * 扫局域网网段（192.168.x.1-254）会产生 254 次探测，既慢又容易被系统判成端口
 * 扫描；而且「模块 + APK 在同一台手机」才是要解决的场景，局域网直连仍走手填。
 *
 * ── 两段式判据（真机踩过的坑）────────────────────────────────
 * 一开始只用 `/health` 的字段特征（`authRequired` / `chatApiUrl` / …）认亲。
 * 真机上是错的：**3.1.0 的 /health 只回 `{"status":"ok"}`**（15 字节），那些
 * 字段是桌面端新版才有的。结果自家网关被判成「不是」，自动发现恒失败。
 *
 * 现在改成两段：
 *   1. `/health` 回 `status: "ok"`（或带新版特征字段）—— 便宜的初筛；
 *   2. `/api/panel/status` 必须回 `{registered: boolean}` —— 这是本家面板独有的
 *      形状，用它兜住「别家也回 status:ok」的误判（3065 上完全可能是别的服务）。
 * 第二段只对通过初筛的候选发，代价可以忽略。
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
  /** 网关版本（响应里有就带上，用于列表展示） */
  version?: string
}

/** 带超时的 JSON GET；任何异常都收敛成 null（探测场景不需要区分错因） */
async function getJson(url: string, timeoutMs: number): Promise<Record<string, unknown> | null> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: { Accept: 'application/json' },
    })
    if (!response.ok) return null
    const body = await response.json().catch(() => null)
    if (!body || typeof body !== 'object') return null
    return body as Record<string, unknown>
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}

/** `/health` 的两种形态都认：3.1.0 的 `{status:"ok"}`，以及新版带特征字段的那份 */
function healthLooksRight(body: Record<string, unknown>): boolean {
  if (body.status === 'ok') return true
  return (
    'authRequired' in body ||
    'chatApiUrl' in body ||
    'upstreamConfigured' in body ||
    'defaultModel' in body ||
    'authApiBase' in body
  )
}

/** `/api/panel/status` 的形状判据：`{success, data:{registered:boolean}}` */
function panelLooksRight(body: Record<string, unknown>): boolean {
  const data = (body.data && typeof body.data === 'object' ? body.data : body) as Record<string, unknown>
  return typeof data.registered === 'boolean'
}

async function probeCandidate(base: string, timeoutMs: number): Promise<Found | null> {
  const health = await getJson(`${base}/health`, timeoutMs)
  if (!health || !healthLooksRight(health)) return null
  const status = await getJson(`${base}/api/panel/status`, timeoutMs)
  if (!status || !panelLooksRight(status)) return null
  const version = typeof health.version === 'string' ? health.version : undefined
  return { base, version }
}

/**
 * 扫环回地址找网关。
 *
 * 21 个候选**并发**探测，每个 1.2 秒超时 —— 最坏 1.2 秒出结果（不是 21 × 1.2）。
 * 环回连接要么立刻拒绝（毫秒级），要么立刻成功，长超时只用来兜住
 * 「端口被防火墙 DROP」这种极端情况。
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
  found.sort((a, b) => Number(a.base.split(':').pop()) - Number(b.base.split(':').pop()))
  return found
}
