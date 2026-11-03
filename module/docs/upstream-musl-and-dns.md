# 怎么把「必须靠模块打补丁」变成「上游一次修好」

现状（实测于 agent2api-server 3.3.0-beta.6 / 模块 magisk.20）：

- 载荷是 **动态链接 glibc** 的 aarch64 程序（`PT_INTERP=/lib/ld-linux-aarch64.so.1`），
  解析走 `getaddrinfo`，因此**必须读 `/etc/resolv.conf`**。
- 载荷里**没有任何 DNS 相关环境变量**（`AGENT2API_*` 只有 HOST / PROXY_PORT / PROXY_HOME /
  UI_DIR / VERBOSE / SELF_UPDATE / ALLOW_NO_KEY / CAPTCHA_ENABLED 等）。
- 上游 release 只发 `agent2api-server-linux-arm64.tar.gz`（glibc），没有 musl 产物。

模块侧为此付出了：打包 glibc 运行时（10 个 .so，约 2.9MB）、等长改写 libc/curl 的
`/etc/resolv.conf` 字符串、维护 `/data/a2a/{resolv,nsswitch,gai}`、DNS 采样与分级兜底、
`lib_verify/lib_restore` 自愈——这一整套都是「载荷离不开 glibc」的代价。

## 方案 A（推荐，改动最小）：给载荷加一个 DNS 环境变量

在解析器初始化处读 `AGENT2API_DNS`，有值就用它构造 hickory 的 Resolver，没有才落回系统解析。

```rust
// 伪代码，位置：创建 reqwest Client / Resolver 的地方
let dns_list = std::env::var("AGENT2API_DNS").ok();
let builder = match dns_list {
    Some(list) => {
        let cfg = ResolverConfig::from_parts(None, vec![],
            list.split(',')
                .filter_map(|s| s.trim().parse::<IpAddr>().ok())
                .map(NameServerConfig::from)
                .collect());
        reqwest::dns::Resolve::builder()
            .config(cfg)
            .options(ResolverOpts::default())
            .build()          // hickory-dns resolver
    }
    None => /* 现有 GaiResolver */,
};
```

收益：模块可以彻底删掉 `/data/a2a` 那一套（resolv/nsswitch/gai + 采样 + 兜底），
DNS 由 wb2api 同款机制接管，行为可预测、零采样、零文件依赖。
在线更新不受影响：资产名不变，sha256 校验链路不变。

## 方案 B（最彻底）：发布 musl 静态构建

`.github/workflows/release.yml` 里加一个 target，产出 `agent2api-server-linux-arm64-musl.tar.gz`：

```yaml
- run: rustup target add aarch64-unknown-linux-musl
- run: cargo build --release --target aarch64-unknown-linux-musl
- run: tar -czf agent2api-server-linux-arm64-musl.tar.gz -C target/aarch64-unknown-linux-musl/release agent2api-server
- run: sha256sum agent2api-server-linux-arm64-musl.tar.gz > agent2api-server-linux-arm64-musl.tar.gz.sha256
```

musl 静态包的特性：
- 无 `PT_INTERP`、无 `libc.so.6` 依赖 → 模块不再需要 glibc 运行时（体积少约 2.9MB）；
- musl 自带解析器读 `/etc/resolv.conf`，Android 上照样不存在，**仍需方案 A 的 `AGENT2API_DNS`**，
  或者让 musl 走它内置的 `RESOLV_CONF` 覆盖——但 musl 的解析器不像 glibc 那样会把 AAAA
  失败传染成整次失败（AA 与 AAAA 分开处理），鲁棒性天然更高。

结论：**A + B 一起做才是根治**；只做 B 仍需 DNS 配置，只做 A 已能干掉模块侧 90% 的复杂度。

## 模块侧已经做好的兼容准备（magisk.20）

- `update_repo` / `update_asset` 可在 `settings.conf` 里改：换 fork、换资产名都不用改脚本，
  `.sha256` 依旧从同一 release 取，校验链路不变。
- 想先自己发一版 musl 静态包验证：设置
  `update_repo=<你的账号>/Agent2API`、`update_asset=agent2api-server-linux-arm64-musl.tar.gz`，
  再 `a2a update` 即可，失败会自动回滚到旧载荷。
