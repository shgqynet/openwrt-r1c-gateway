# NETWORK.md — 网络架构与现场可变配置

## 1. 核心设计原则：网段不进固件

现场 PLC 网段不固定，VPN 网段也常要调整。因此本项目**不把任何网段编译进固件**：

| 传统做法（本项目不采用） | 本项目做法 |
| --- | --- |
| 把 `192.168.10.0/24` 写死进 `/etc/config/network` | 固件只带占位值，真实值在 `/etc/r1c/site.conf` |
| 换现场需重新编译固件 | 改 `site.conf` 后执行 `r1c-apply`，即时生效 |
| 网段变更要重启整机 | 只 reload 网络/防火墙（需求 §37：禁止无条件重启） |

依据：需求 §27（现场配置文件）、§9（PLC 网络）、§8（VPN 网段）。

---

## 2. 配置层次

```
/etc/r1c/site.conf          <- 唯一真相源，现场填写（运行时可改）
        │
        │  r1c-apply
        ▼
UCI: network / firewall / wireguard / zerotier
        │
        │  reload（不重启）
        ▼
   实际生效的网络
```

`r1c-gateway` 服务启动时若 `AUTO_APPLY=1` 会自动执行一次 `r1c-apply`。
**校验不通过时自动跳过**，不会把残缺配置写进网络。

---

## 3. PLC 侧角色：`PLC_ROLE`（现场千差万别，两种都支持）

这是最容易踩坑的地方——R1C 在 PLC 网段里到底算什么，决定了回包能否走通。

### `PLC_ROLE="gateway"` — R1C 作为 PLC 网段网关

```
工程师 VPN ──► R1C(wg0) ──► R1C(lan .1) ──► PLC(.10/.20/.30)
                              ▲
                    PLC 的网关就是 R1C，回包天然经过它
```
- R1C 占用 `PLC_GATEWAY`（如 `192.168.10.1`）
- **前提**：现场 PLC/交换机把网关指向 R1C，或已加指向 R1C 的静态路由
- **不需要 SNAT**：PLC 回包的目的地址是 VPN 地址，会直接交给网关（R1C）转发

### `PLC_ROLE="host"` — R1C 只是网段内一台主机

```
工程师 VPN ──► R1C(wg0) ──► R1C(lan .254) ──► PLC(.10)
                                                  │
                                    回包走现场原网关 .1 ──► ?（无 VPN 路由）
```
- R1C 占用 `PLC_LOCAL_IP`（如 `192.168.10.254`），**现场原有网关不动**
- 对现有网络零改动 —— 这是它最大的价值
- **风险**：PLC 回包会走现场原网关，而原网关通常没有到 VPN 网段的路由 → 工程师收不到响应
- **对策**：`PLC_SNAT=auto` 时自动开启 MASQUERADE，把源地址换成 R1C 的 LAN IP，
  PLC 看到的源是同网段地址，回包自然回到 R1C

> 如果现场原网关可以加静态路由（到 VPN 网段指向 R1C），则可以把 `PLC_SNAT="0"` 关掉，
> 让 PLC 看到工程师的真实 VPN 地址（利于审计与某些依赖源地址的协议）。

---

## 4. 关键参数速查

| 参数 | 说明 | 改后需 apply |
| --- | --- | --- |
| `PLC_NETWORK` | 现场 PLC 网段，如 `192.168.10.0/24` | ✅ |
| `PLC_ROLE` | `gateway` / `host` | ✅ |
| `PLC_GATEWAY` | gateway 模式下 R1C 占用的地址 | ✅ |
| `PLC_LOCAL_IP` | host 模式下 R1C 占用的地址 | ✅ |
| `PLC_UPSTREAM_GW` | host 模式下现场现有网关 | ✅ |
| `PLC_WAN_ACCESS` | PLC 能否访问公网，`deny`（默认）/ `allow` | ✅ |
| `PLC_SNAT` | `auto` / `1` / `0`，见上文 | ✅ |
| `PLC_MAP_NETWORK` | **预留**（需求 §25 多站点同网段映射），暂不实现 | — |
| `VPN_MODE` | `wireguard` / `zerotier` | ✅ |
| `VPN_ADDR` | WireGuard 隧道地址，如 `10.250.1.20/16` | ✅ |
| `WG_ENDPOINT` | Hub 公网端点 `host:port` | ✅ |
| `WG_PEER_PUBLIC_KEY` | 对端公钥 | ✅ |
| `WG_PRIVATE_KEY_FILE` | 私钥**文件路径**（私钥绝不写进 site.conf） | ✅ |
| `PLC_DEVICES` | PLC 健康检查列表，每行 `名称\|IP\|类型\|描述` | 诊断用 |

---

## 5. 防火墙分区（需求 §20）

`r1c-apply` 会自动创建：

| Zone | 成员 | input | forward |
| --- | --- | --- | --- |
| `plc` | `lan`（PLC 侧） | ACCEPT | REJECT |
| `vpn` | `wg0` / `zt0` | **REJECT** | REJECT |
| `wan` | 现有 WAN | — | — |

转发规则：

- **vpn → plc：ACCEPT**（§20 核心，工程师经 VPN 访问 PLC）
- **plc → wan：默认 REJECT**（§20：按现场要求；工业现场通常禁止 PLC 出公网）
- **vpn → 路由器自身：REJECT**（§62：管理接口不对 VPN 全开，按 §31 角色另行授权）

⚠️ 未做任何公网端口暴露（§11/§61）：不存在 Internet → PLC 的放行规则，
SSH / LuCI 也不会从 WAN 可达。

---

## 6. 改网段的现场操作流程

```sh
vi /etc/r1c/site.conf          # 改 PLC_NETWORK / PLC_GATEWAY / PLC_DEVICES / VPN_ADDR ...

r1c-apply --check              # 先自检，不改动任何东西
r1c-apply --dry-run            # 看看将要写哪些 UCI 项
r1c-apply                      # 真正应用

r1c-status                     # 核对 "LAN (applied)" 与 site.conf 是否一致
r1c-diagnose                   # 完整诊断报告
```

改网段时的两个易漏点：

1. **`PLC_DEVICES` 里的 IP 要跟着改**，否则健康检查还在探测旧网段
2. **host 模式改网段后确认 SNAT 已生效**，否则工程师能发出去但收不到回包

---

## 7. 多站点同网段（需求 §25）：暂不实现

需求 §25 要求支持多个现场都用 `192.168.10.0/24`。当前**未实现**，仅预留 `PLC_MAP_NETWORK` 参数位。

后续若要实现，方向是在 VPN 侧做 **NETMAP 1:1 地址映射**：

```
Site A: PLC 192.168.10.0/24  ←→  虚拟 10.251.1.0/24
Site B: PLC 192.168.10.0/24  ←→  虚拟 10.251.2.0/24
工程师访问 10.251.1.30  =  Site A 的 192.168.10.30
```

已知代价：PLC 看到的源地址不再是工程师真实地址，
部分工业协议（依赖源 IP 的会话/授权）可能异常——因此留到真实需求出现时再评估。

当前约束仍然成立：**禁止把多个同网段站点桥接到同一个 L2 网络**（§25），一律走 L3 路由。

---

## 8. 安全约束

- **私钥不进仓库**：`site.conf` 只保存 `WG_PRIVATE_KEY_FILE` 路径，
  真实私钥由现场写文件（600 权限）。这是公开仓库下的红线。
- `site.conf` 中的 `WIFI_KEY` / `WG_PEER_PUBLIC_KEY` 等也必须留空占位，现场填。
- `r1c-apply` 不执行任何 `mtd` / `sysupgrade` / U-Boot 操作（需求 §64）。
