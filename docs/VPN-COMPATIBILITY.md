# VPN-COMPATIBILITY.md — VPN 方案在 ramips/mt7620 (R1C) 上的兼容性

> 阶段：Phase 1（调查）— 未刷机，未进行真机运行测试
> 原则（需求 §67）：**结论必须基于实际编译/安装数据，不得仅凭互联网文章判断。**
> 本文的"实测"指：直接读取 OpenWrt 官方下载站 `Packages.gz` 索引的架构字段与体积字段、官方源码 Makefile、官方镜像 Content-Length。
> 真机运行类指标统一标记 `[PENDING]`，需 Phase 3 / Phase 7 / Phase 8 上电验证。

---

## 1. 结论总表

| VPN | MIPS(mipsel_24kc) | OpenWrt 包 | Subnet Router | RAM | Flash | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| **WireGuard** | ✅ 支持（内核模块 + 用户态工具） | ✅ 官方原生（`kmod-wireguard` + `wireguard-tools`） | ✅ 支持（AllowedIPs + 静态路由 + 内核转发） | ✅ 极低（约 2–5 MB，`[PENDING]` 实测） | ✅ 极小（约 0.2–0.4 MiB） | **PRIMARY（默认）** |
| **ZeroTier** | ✅ 支持（C++，1.14.1 有 mipsel_24kc 构建） | ✅ packages feed `net/zerotier` | ✅ 支持（Managed Routes + `ip_forward`） | ⚠️ 中（约 15–30 MB，`[PENDING]`） | ✅ 1.0 MiB（ipk 0.48 MiB） | **OPTIONAL（备用）** |
| **Tailscale** | ⚠️ 架构上有构建（1.80.3 mipsel_24kc，Go） | ✅ packages feed `net/tailscale` | ✅ 支持（`--advertise-routes`） | ⚠️ 高（Go 运行时，约 30–60 MB） | ❌ **24.9 MiB 安装体积，超预算** | **EXPERIMENTAL — 不建议入固件** |
| **Cloudflare (cloudflared)** | ⚠️ 社区源码可编译（2025.5.0 mipsel_24kc）；Cloudflare 官方**不发布 MIPS 二进制** | ⚠️ packages feed `net/cloudflared` | ⚠️ 受限（WARP routing 支持 TCP/UDP，**不转发 ICMP**） | ❌ 高（Go，约 40–80 MB） | ❌ **25.9 MiB 安装体积，超预算** | **NOT SUPPORTED ON R1C** |

---

## 2. 判定依据（原始数据）

数据来源：OpenWrt 官方下载站 `https://downloads.openwrt.org/releases/24.10.5/packages/mipsel_24kc/packages/Packages.gz`（curl 获取后解析字段）

| 包 | 版本 | 架构 | ipk 体积 | 安装体积 | 依赖 |
| --- | --- | --- | --- | --- | --- |
| `zerotier` | 1.14.1-r3 | **mipsel_24kc** | 0.48 MiB（501294 B） | 1.0 MiB（1064960 B） | libpthread, libstdcpp, kmod-tun, ip, libminiupnpc, libnatpmp, libatomic |
| `tailscale` | 1.80.3-r1 | **mipsel_24kc** | 8.21 MiB（8604520 B） | **24.9 MiB（26081280 B）** | libc, ca-bundle, **kmod-tun** |
| `cloudflared` | 2025.5.0-r1 | **mipsel_24kc** | 7.79 MiB（8169249 B） | **25.9 MiB（27197440 B）** | libc, ca-bundle |
| `golang` | 1.23.12-r2 | **mipsel_24kc** | 39.7 MiB | — | 说明 Go 工具链对 mipsel_24kc 可构建 |

### 2.1 Flash 预算判定（关键）

```
firmware 分区            = 15872 KiB (15.5 MiB)   [mt7620.mk IMAGE_SIZE]
官方 24.10.5 基础镜像     =  6528 KiB (6.38 MiB)   [Content-Length 实测]
剩余可分配预算            =  9344 KiB (约 9.1 MiB)
```

| 方案 | 额外占用（squashfs 压缩后估算） | 是否放得下 |
| --- | --- | --- |
| WireGuard（kmod + tools） | ≈ 0.3 MiB | ✅ 轻松 |
| ZeroTier | ≈ 1.0 MiB | ✅ 可行 |
| Tailscale | ≈ 8 MiB（未压缩 24.9 MiB） | ❌ 放下后 overlay 几乎归零，且无法与 ZeroTier/LuCI 共存 |
| cloudflared | ≈ 8 MiB（未压缩 25.9 MiB） | ❌ 同上 |

> 说明：squashfs 会二次压缩，Go 二进制压缩率约 3:1，因此 24.9 MiB 未压缩 ≈ 8 MiB 落盘。
> 即便如此，`6.38 + 8 = 14.4 MiB` 已逼近 15.5 MiB 上限，且**没有余量给 overlay（配置/日志/证书）**，不符合需求 §43/§44 与工业稳定性优先原则（§72）。

---

## 3. 逐项调查

### 3.1 WireGuard — ✅ PRIMARY

| 调查项 | 结论 |
| --- | --- |
| MIPS 支持 | ✅ `kmod-wireguard` 为架构无关的内核模块，mt7620（mipsel_24kc）可构建 |
| OpenWrt 支持 | ✅ 官方原生，含 `luci-proto-wireguard`；Lean lede 亦含 |
| Subnet Router | ✅ 通过 `AllowedIPs` + 对端静态路由 + `net.ipv4.ip_forward=1` 实现"VPN → PLC LAN"三层路由 |
| PersistentKeepalive | ✅ `PersistentKeepalive = 25`，适配 4G/CGNAT/手机热点（需求 §18） |
| 时间同步依赖 | ⚠️ WireGuard 本身不校验时间戳，但**证书/密钥轮换、日志与排障依赖正确时间**，且系统时间异常会影响 `wg` 握手日志判断 → 仍需按需求 §19 先 NTP 后 VPN |
| 加密性能 | ⚠️ MT7620A **无硬件加密引擎**（DTS 无 crypto 节点），ChaCha20 软算，吞吐 `[PENDING]` 实测 |
| 依赖 | `kmod-wireguard`、`wireguard-tools`、`kmod-udptunnel`*、`kmod-iptunnel`*（随依赖自动带入） |
| 结论 | **作为默认 VPN（Mode 1），必须实现** |

### 3.2 ZeroTier — ✅ OPTIONAL / FALLBACK

| 调查项 | 结论 |
| --- | --- |
| MIPS 支持 | ✅ 官方索引存在 `zerotier 1.14.1-r3 mipsel_24kc`；ZeroTier 为 C++ 实现，无 Go 运行时包袱 |
| OpenWrt 支持 | ✅ `packages` feed `net/zerotier`，Makefile 依赖：libpthread、libstdcpp、**kmod-tun**、ip、libminiupnpc、libnatpmp、libatomic |
| Subnet Router | ✅ ZeroTier 原生支持 Managed Routes，可作为 Site/Subnet Router 通告 `192.168.10.0/24`；OpenWrt 侧需开启 `ip_forward` 与相应 forward 规则 |
| TUN | ✅ 需要 `kmod-tun`（与 WireGuard 无冲突，但**不可让两个 VPN 同时成为同一 PLC 子网的默认路由**，需求 §7） |
| RAM | ⚠️ `[PENDING]` 实测；128 MiB RAM 预计可承受 |
| Flash | ✅ 1.0 MiB |
| 结论 | **作为可选备用（Mode 2），纳入 profile 但默认关闭** |

### 3.3 Tailscale — ⚠️ EXPERIMENTAL（不建议入固件）

| 调查项 | 结论 |
| --- | --- |
| MIPS 支持 | ⚠️ **架构层面存在构建**：索引有 `tailscale 1.80.3-r1 mipsel_24kc`。OpenWrt 由源码用 Go 编译（Makefile `PKG_BUILD_DEPENDS:=golang/host`，`DEPENDS:=$(GO_ARCH_DEPENDS)`）。**Cloudflare/Tailscale 官方均不发布 MIPS 预编译二进制** |
| 运行风险 | ⚠️ Go 的 `mipsle` 端口与 soft-float（MT7620A 无 FPU）组合是主要风险点；**必须在真机上验证 `tailscaled` 能启动且不 SIGILL** `[PENDING]` |
| OpenWrt 支持 | ✅ `packages` feed `net/tailscale` |
| Subnet Router | ✅ 支持 `--advertise-routes`，功能上满足需求 |
| TUN | ✅ 依赖 `kmod-tun` |
| RAM | ⚠️ Go 运行时 + 控制面，128 MiB 上偏紧，`[PENDING]` 实测 |
| Flash | ❌ **24.9 MiB 安装体积 — 决定性否决项** |
| 结论 | **不加入固件**。按需求 §5："如果当前官方/社区版本不能可靠支持 R1C，不要强行加入固件。" |
| 后续 | 若未来需要，只能作为 **外部网关**（部署在云端/工控机），R1C 不承载 |

### 3.4 Cloudflare — ❌ NOT SUPPORTED ON R1C

| 调查项 | 结论 |
| --- | --- |
| cloudflared 是否支持 MIPS | ⚠️ **社区从源码编译**可得 `mipsel_24kc`（2025.5.0-r1）；**Cloudflare 官方 release 不提供 linux-mips 二进制** |
| Cloudflare Mesh 是否支持 MIPS | ❌ 无官方 MIPS 支持 |
| Cloudflare One Client（WARP 客户端）是否支持 MIPS | ❌ 官方客户端无 MIPS 版本 |
| 是否可作 Site/Subnet Router | ⚠️ cloudflared 的 WARP routing（`--cloudflared route ip`）可做子网路由，但依赖 cloudflared 常驻 |
| 是否支持 TCP | ✅ 支持 |
| 是否支持 UDP | ✅ 支持 |
| 是否支持 **ICMP** | ❌ **不转发 ICMP** → 直接影响需求 §34"PLC Health Check 只做 ICMP Ping"，工程上不可接受 |
| 是否适合 S7/AB PLC 通信 | ❌ 不适合：ICMP 缺失 + Flash 超预算 + Go 内存开销 |
| Flash | ❌ 25.9 MiB 安装体积 |
| 结论 | **标记 `NOT SUPPORTED ON R1C`**。按需求 §6："如果没有可靠 MIPS 支持，标记 NOT SUPPORTED ON R1C，不要为了 Cloudflare 修改底层系统。" |
| 替代 | Cloudflare 可作为 **External Gateway**（云端侧），R1C 端仍用 WireGuard/ZeroTier |

---

## 4. 与需求条目的对应关系

| 需求 | 结论 |
| --- | --- |
| §5 Mode 1 WireGuard（Primary） | ✅ 采纳，必须实现 |
| §5 Mode 2 ZeroTier（Optional） | ✅ 采纳为备用，默认关闭 |
| §5 Mode 3 Tailscale（Experimental） | ⚠️ 第一阶段验证完成（架构有包），**Flash 否决，不入固件** |
| §6 Cloudflare 调查 | ✅ 调查完成，结论 `NOT SUPPORTED ON R1C` |
| §7 VPN 优先级 | ✅ WireGuard > ZeroTier >（Tailscale 实验/外部） > Cloudflare（外部） |
| §7 不同时运行多 VPN 作为同一 PLC 子网默认路由 | ✅ 写入设计约束，r1c-gateway 服务需做互斥检查 |
| §18 Keepalive | ✅ WireGuard `PersistentKeepalive=25` |
| §19 NTP 先于 VPN | ✅ 写入启动顺序 |
| §25 多站点同网段 | ✅ 全部走 **L3 routing**，禁止 L2 桥接；WireGuard 用 `AllowedIPs` 精确指向各站点 PLC 网段 |

---

## 5. `[PENDING]` 真机验证项（Phase 3 / 7 / 8）

1. WireGuard 在 MT7620A 上的实际吞吐（Mbps）与 CPU 占用。
2. WireGuard 长连 72h 稳定性、4G/热点切换后自动恢复。
3. ZeroTier 1.14.1 在 128 MiB RAM 上的常驻内存。
4. `kmod-tun` 与 WireGuard 并存时的资源占用。
5. Tailscale（若仍要坚持）在 soft-float mipsle 上是否 SIGILL —— **仅在有外部 Flash 预算时才做**。
6. PLC 侧 ICMP/TCP 102 穿越 WireGuard 的可达性（Phase 10）。
