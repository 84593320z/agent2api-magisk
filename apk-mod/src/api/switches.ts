/**
 * 网关功能开关：与桌面面板「设置 → 网关」里的那组开关**同一批端点、同一批字段**。
 *
 * ── 为什么单独一个模块 ────────────────────────────────────────
 * 这些开关在服务端是 6 个独立端点 + 1 个 `/api/routing`（三个自愈开关共用），
 * 每个端点的读写形状完全同构：`GET` 读全量状态、`PUT` 写**部分**字段、
 * 响应体就是写入后的新状态。把这个规律收敛在一张表里，加一个开关只改一行，
 * 而不是在页面里散落 9 段 fetch。
 *
 * ── 为什么字段名照抄后端 ──────────────────────────────────────
 * 后端键（`sanitizeBlacklistFingerprints` 这类）与前端展示名没有推导关系。
 * 桌面端踩过一次坑（`PROTECTION_STATE_FIELD` 的注释里写着「拼出来的名字一旦
 * 对不上，表现是开关点了没反应」），这里同样显式列表，不拼字符串。
 *
 * ── 双向同步是怎么成立的 ──────────────────────────────────────
 * 没有推送通道，靠「同一份服务端状态 + 两端各自回读」：
 *   · 面板改了 → 手机端在设置页可见时每 5 秒回读一次（见 SettingsPage），
 *     切回前台也会立刻回读；
 *   · 手机改了 → PUT 成功后响应体就是新状态，界面直接用它渲染；面板下次
 *     刷新自然读到。
 * 写操作是**幂等**的（PUT 同一份值），所以两边同时拨不会互相打架。
 */

import { apiCall } from './client'

/** 开关所属分组：网关行为 / 路由自愈（与桌面设置页的两个小节对应） */
export type SwitchGroup = 'gateway' | 'protection'

export type SwitchId =
  | 'sanitize'
  | 'developerRoleCompat'
  | 'cors'
  | 'debug'
  | 'captcha'
  | 'modelsDev'
  | 'failoverBackoff'
  | 'sink'
  | 'breaker'

export type SwitchDef = {
  id: SwitchId
  group: SwitchGroup
  /** GET 读 / PUT 写的端点 */
  path: string
  /** 请求与响应里的字段名（照抄后端，不推导） */
  field: string
  /** 字段缺失时的口径，与桌面端各 render 函数保持一致 */
  fallback: boolean
  /** 展示用文案（中文原文即 i18n key，其余语种查不到时回落中文） */
  label: string
  hint: string
}

export const SWITCH_DEFS: SwitchDef[] = [
  {
    id: 'sanitize',
    group: 'gateway',
    path: '/api/sanitize',
    field: 'sanitizeBlacklistFingerprints',
    fallback: false,
    label: '出站指纹脱敏',
    hint: '剥离上游审核黑名单指纹：改写请求体里的模板句与表头',
  },
  {
    id: 'developerRoleCompat',
    group: 'gateway',
    path: '/api/developer-role-compat',
    field: 'developerRoleCompat',
    fallback: false,
    label: '开发者角色兼容',
    hint: '转发前把 developer 角色消息转成 system，兼容不认该角色的上游',
  },
  {
    id: 'cors',
    group: 'gateway',
    path: '/api/cors',
    field: 'corsEnabled',
    fallback: false,
    label: '网关跨域访问',
    hint: '允许浏览器里的页面跨来源调用网关 /v1/*',
  },
  {
    id: 'debug',
    group: 'gateway',
    path: '/api/debug',
    field: 'debugMode',
    fallback: false,
    label: '调试模式',
    hint: '保存上游原始报文（请求头/体、响应头/体），排查时才有现场',
  },
  {
    id: 'captcha',
    group: 'gateway',
    path: '/api/captcha',
    field: 'captchaEnabled',
    fallback: true,
    label: '登录人机校验',
    hint: '登录 / 注册需要通过 ALTCHA 人机验证（工作量证明）',
  },
  {
    id: 'modelsDev',
    group: 'gateway',
    path: '/api/models/metadata',
    field: 'modelsDevEnabled',
    fallback: true,
    label: 'models.dev 元数据',
    hint: '用 models.dev 补齐上游没声明的模型能力与思考档位（联网刷新）',
  },
  {
    id: 'failoverBackoff',
    group: 'protection',
    path: '/api/routing',
    field: 'routingFailoverBackoff',
    fallback: true,
    label: '失败退避',
    hint: '失败账号休息 15 分钟起步、连续失败翻倍、成功一次立即恢复',
  },
  {
    id: 'sink',
    group: 'protection',
    path: '/api/routing',
    field: 'routingSink',
    fallback: true,
    label: '限流垫底',
    hint: '有额度却被 429 的账号排到队尾，30 分钟后自动归队',
  },
  {
    id: 'breaker',
    group: 'protection',
    path: '/api/routing',
    field: 'routingBreakerEnabled',
    fallback: false,
    label: '熔断',
    hint: '连续失败到阈值后整个账号跳过，要连续成功若干次才恢复',
  },
]

/** 读到的开关状态；某个键缺失 = 该端点读失败，界面按「未知」处理（禁用而不是猜） */
export type SwitchState = Partial<Record<SwitchId, boolean>>

function pick(body: unknown, def: SwitchDef): boolean | undefined {
  if (!body || typeof body !== 'object') return undefined
  const raw = (body as Record<string, unknown>)[def.field]
  return typeof raw === 'boolean' ? raw : undefined
}

/**
 * 并发读全部开关。
 *
 * 按**端点**去重（`/api/routing` 一条请求喂三个开关），任一端点失败不影响其余
 * —— 面板上某个功能被关掉时那个端点可能整个不可用，不能让整页跟着报错。
 */
export async function fetchSwitches(signal?: AbortSignal): Promise<SwitchState> {
  const paths = Array.from(new Set(SWITCH_DEFS.map(def => def.path)))
  const bodies = new Map<string, unknown>()
  await Promise.all(
    paths.map(async path => {
      try {
        bodies.set(path, await apiCall(path, { signal, quiet: true }))
      } catch {
        bodies.set(path, undefined)
      }
    }),
  )
  const state: SwitchState = {}
  for (const def of SWITCH_DEFS) {
    const value = pick(bodies.get(def.path), def)
    if (value !== undefined) state[def.id] = value
  }
  return state
}

/**
 * 写一个开关。返回**同端点上所有开关**的新值（响应体是整份状态）。
 *
 * 调用方负责乐观更新与失败回滚。这里在两种情况下抛错：
 *   1. 网络/接口失败；
 *   2. 后端回了 200 但**没有确认这个字段**——响应体缺字段，或回显值
 *      与请求不一致。旧实现缺字段时按请求值伪造成功（伪成功），界面
 *      显示和网关实际状态从此各说各话；宁可报错回滚，也不假装写成功。
 */
export async function saveSwitch(id: SwitchId, next: boolean): Promise<SwitchState> {
  const def = SWITCH_DEFS.find(item => item.id === id)
  if (!def) return {}
  const body = await apiCall(def.path, { method: 'PUT', body: { [def.field]: next } })
  const state: SwitchState = {}
  for (const item of SWITCH_DEFS) {
    if (item.path !== def.path) continue
    const value = pick(body, item)
    if (value !== undefined) state[item.id] = value
  }
  if (state[id] === undefined) {
    throw new Error(`网关响应缺少 ${def.field}，未确认设置已生效`)
  }
  if (state[id] !== next) {
    throw new Error(`网关回显 ${def.field}=${String(state[id])} 与请求不一致`)
  }
  return state
}

/** 分组 → 该组开关（渲染顺序就是表里的顺序） */
export function switchesOf(group: SwitchGroup): SwitchDef[] {
  return SWITCH_DEFS.filter(def => def.group === group)
}
