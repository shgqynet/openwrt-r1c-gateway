# R1C 工业远程网关固件

> Xiaomi MiWiFi Mini（R1C）刷 OpenWrt 24.10，改造成**工业现场 PLC 远程维护网关**。
> 现场只需任意能上网的链路（手机热点 / 4G / 有线）→ WireGuard 隧道 → 工程师在本地用 TIA Portal、STEP 7 直连 PLC 下载、监控、改程序。

[English](README_EN.md) | 简体中文

| 项 | 值 |
| --- | --- |
| 设备 | Xiaomi MiWiFi Mini（R1C / R1CM） |
| 源码 | `openwrt/openwrt` 分支 `openwrt-24.10`（kernel 6.6.x） |
| 目标 | `ramips/mt7620` → `xiaomi_miwifi-mini`，架构 `mipsel_24kc` |
| 主链路 | WireGuard（ZeroTier 备用） |
| 构建方式 | GitHub Actions 云端一键构建，也可本地 `build.sh` |
| 固件分区 | `firmware` 15872 KiB，产出的 sysupgrade 约 10.4 MiB |

---

## 1. 它解决什么问题

现场 PLC 在内网里（例如 `192.168.10.30`，西门子 TCP/102 或 Modbus TCP/502），
工程师在办公室。传统做法是跑现场、或者让客户配端口映射/VPN —— 成本高、不可控、且往往不允许动客户网络。

本方案把一台几十块钱的 R1C 放在 PLC 机柜里：它自己通过手机热点或 4G 上网，
主动向 Hub 发起 WireGuard 隧道；工程师连上 Hub 之后，**在自己电脑上直接填 PLC 的内网 IP 就能连上**，
就像人坐在现场一样。

```
   办公室 / 家中                      Internet                      工业现场
┌──────────────────┐           ┌──────────────┐             ┌──────────────────┐
│ Engineer PC      │ WireGuard │              │  hotspot /  │      R1C         │
│ TIA / STEP 7 ────┼──────────▶│  Hub  (VPN)  │◀── 4G ──────┼── WAN (STA)      │
│ ping / browser   │  tunnel   │  UDP 51821   │  ETH        │        │         │
└──────────────────┘           └──────────────┘             │        ▼         │
                                                            │  PLC 192.168.10.x│
                                                            │  HMI / switch    │
                                                            └──────────────────┘
```

关键点：**R1C 是主动外连的一方**，现场网络不需要开放任何入站端口、不需要<｜hy_place▁holder▁no▁813｜>映射、
也不需要改动客户原有网关（见下文的 `PLC_ROLE=host` 模式）。

---

## 2. 特性

| 分类 | 说明 |
| --- | --- |
| **网段零编译** | PLC 网段、VPN 地址全部放在 `/etc/r1c/site.conf`，改完执行 `r1c-apply` 立即生效，**不用重新编译固件、不用重启** |
| **两种接入角色** | `PLC_ROLE=gateway`（R1C 当 PLC 网段的网关）/`host`（R1C 只是网段里一台主机，现场网络零改动） |
| **隧道自愈** | `r1c-wg-watchdog` 每 30 秒重解析 Hub 域名 —— WireGuard 内核只缓存 IP，家宽重拨换 IP 后 DDNS 救不了隧道，必须靠它 |
| **DNS 无关上行** | 支持以太网 / USB 4G / USB 共享网络 / WiFi STA 四种上行，按 `WAN_PRIORITY` 自动选择 |
| **断网不死锁** | 5G 射频常开一个应急 AP，配本地管理页 `/cgi-bin/r1c`，隧道断了也能用手机连上去改 WiFi（详见 §6） |
| **本地应急管理页** | 纯 busybox ash 写的 CGI，5 个页签，零额外依赖 —— 隧道断了照样能开 |
| **LuCI 入口** | 后台菜单「R1C 工业网关」直接嵌上面的管理页，出厂自带 |
| **升级不丢配置** | `keep.d/r1c-gateway` 让 `/etc/r1c/` 随 sysupgrade 保留 —— 站点配置和 WG 私钥不会被升级抹掉 |
| **中文界面** | 出厂注入 LuCI 简体中文语言包 |
| **只读体检** | `r1c-status` / `r1c-diagnose` 只做 ICMP 与 TCP 连通性探测，**不向 PLC 发任何写命令** |

### 明确不支持 / 不推荐

| 方案 | 结论 |
| --- | --- |
| Tailscale | 安装体积 24.9 MiB，**超 flash 预算**，未纳入固件 |
| cloudflared | 25.9 MiB，且 WARP routing 不转发 ICMP（ping 不通），放弃 |
| 多站点 L2 桥接 | 禁止。多个站点同网段时必须走 L3 路由 + 地址映射 |

---

## 3. 快速开始

### 3.1 直接用预编译固件（推荐）

```bash
# 从 Release 页下载（本仓库为私有仓库，需用 gh 登录）
gh release download <版本号> -R <owner>/<repo> -p "*.bin" -p "sha256sums"

# 校验
sha256sum -c sha256sums
```

Release 里每件产物的用途：

| 文件 | 用途 |
| --- | --- |
| `r1c-gateway-<版本>-sysupgrade.bin` | **刷机用这个**（正式写入 Flash） |
| `r1c-gateway-<版本>-initramfs-kernel.bin` | 临时RAM系统，用于 breed 里第一次刷入或救砖，**不写 Flash** |
| `sha256sums` | 镜像校验和 |
| `manifest` | 构建元信息（源码 commit、内核版本、镜像大小、VPN 选型结论） |
| `config.buildinfo` | 本次构建用的完整 `.config`，复现构建时对照 |
| `build.log` | 编译日志摘录（错误/警告全量 + 尾部 3000 行） |

### 3.2 自行构建

见 [docs/BUILD.md](docs/BUILD.md)。两条路，产出等价：

```bash
# A. 本地构建（需要 ≥30GB 磁盘、非 root 用户）
./build.sh            # 全量：拉源码 → feeds → 配置 → 编译 → 体积检查 → 生成 release 包
./update.sh           # 增量（保留缓存）

# B. 云端构建（推荐）
git push origin main  # 改动 configs/ files/ package/ patches/ diy-*.sh 时自动触发
# 或在 GitHub Actions 页面手动 Run workflow，可勾 ignore-lock 使用最新源码
```

云端构建约 **50–95 分钟**，成功后自动发布 Release，版本号格式 `YYYY.MM.DD-HHMM`。

> 源码 commit 由 `source.commit` 锁定，目的是**可复现**。要跟进上游更新就改这个文件，不要悄悄漂版本。

---

## 4. 刷机

完整作业手册见 [docs/FLASH-RUNBOOK.md](docs/FLASH-RUNBOOK.md)，原理与排查见 [docs/FIRST-BOOT.md](docs/FIRST-BOOT.md)。这里只说最容易翻车的几条。

### ⛔ 三条红线

1. **先备份 `factory` 和 `Bdata` 分区，并存到电脑**。前者存无线 EEPROM 与 MAC，丢了无线**永久报废且无法从其他机器复制**。
2. **禁止** `mtd write` 之外的任何分区操作、禁止改 U-Boot/分区表、禁止写 `factory` / `Bdata` / `u-boot-env`。
3. `breed` 的「固件启动设置 → 类型」必须选 **小米 MINI**。选错的现象是"能刷进去但起不来"。

### 流程概要

```
breed(192.168.1.1) ──刷 initramfs(RAM系统，不写Flash)──▶ 进 OpenWrt ──sysupgrade──▶ 正式固件
```

```sh
# 已在 RAM 系统里时
sysupgrade -T /tmp/xxx-sysupgrade.bin   # 先做升级前检查
sysupgrade     /tmp/xxx-sysupgrade.bin  # 再刷（被拒时不要用 -F 强刷）
```

> ⚠️ **刷完后首次上线约需 7 分钟**（实测 6.5–7 分钟）。这段时间内 ping 不通、SSH 连不上都属正常，
> 不要急着判断是否刷砖 —— 判断依据看**本机有线网卡是否仍显示已连接 100Mbps**，只要还连着就是在写 Flash。

---

## 5. 站点配置：`/etc/r1c/site.conf`

**这是现场唯一需要改的文件。** 固件里全是占位值，不编译任何真实网段。

```sh
vi /etc/r1c/site.conf
r1c-apply --check     # 先校验
r1c-apply --dry-run   # 看它打算改什么（强烈建议）
r1c-apply             # 真正落地，reload 网络/防火墙，不重启
```

### 必填项

| 参数 | 说明 | 常见坑 |
| --- | --- | --- |
| `SITE_ID` | 站点标识，全局唯一 | 多站点重名会互相顶掉路由 |
| `PLC_ROLE` | `gateway` / `host` | host 模式要求现场已有网关有到 VPN 网段的回程路由 |
| `PLC_NETWORK` | PLC 网段，如 `192.168.10.0/24` | — |
| `PLC_GATEWAY` / `PLC_LOCAL_IP` | 按角色二选一 | LAN **永不配默认网关**，否则与 WAN 抢路由、掐断隧道自身 |
| `VPN_ADDR` | 本端隧道地址，**每站点唯一** | — |
| `WG_ENDPOINT` | Hub 的公网端点 `域名:端口` | — |
| `WG_PEER_PUBLIC_KEY` | Hub 的公钥 | — |
| `WG_PEER_ALLOWED_IPS` | 走隧道的目的网段 | **绝不可填 `0.0.0.0/0`**，会把默认路由指进隧道掐断上行 |
| `WG_PRIVATE_KEY_FILE` | 私钥文件路径 | 私钥**不写进 site.conf**（会进仓库），单独存文件，权限 600 |
| `WG_PRESHARED_KEY_FILE` | PSK 文件路径 | 缺失只会表现为 handshake timeout，很难查 |
| `AUTO_APPLY` | 开机是否自动 apply | **出厂必须为 0**，否则占位配置会改 LAN 地址导致首次刷机"打不开 192.168.1.1"的假象 |

### 安全相关

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `PLC_WAN_ACCESS` | `deny` | 禁止 PLC 侧主动访问公网 |
| `VPN_HTTP_ACCESS` | `deny` | 是否允许从 VPN 侧打开管理后台。**设 `allow` 前必须先 `passwd root`** —— 未设密码时 `r1c-apply` 会拒绝放行并告警，避免出厂裸奔 |
| `REMOTE_MAINTENANCE` | `disabled` | 远程维护开关与超时 |

### 多上行与自动切换（4G 默认作备用）

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `WAN_PRIORITY` | `ethernet wifi usb4g usbtether` | 上行优先级，**4G 出厂定位为备用**：网线、热点都断掉时 4G 才顶上 |
| `WAN_FAILOVER` | `mwan3` | `mwan3` 主动探测（能识别"插着线但没网"）/ `metric` 仅靠内核选路 / `off` |
| `MWAN_TRACK_IPS` | 三个公共 DNS | 探测点。**别填 Hub 地址** —— 探测点一挂会误判并把上行整体切走 |
| `WAN_4G_DEVICE` / `WAN_TETHER_DEVICE` | `auto` | 按驱动名自动探测；也可写死 `eth1` / `usb0` |

- **有线 WAN 开箱即用**：插上能上网的网线自动出网，不需要任何配置。4G 与 USB 共享属备用手段。
- **USB 4G 模块插上默认停在 U 盘模式**，由 `usb-modeswitch` 切成网卡后才可用。
  实测华为 E3131：`12d1:1f01`（U 盘）→ `12d1:14db`，`cdc_ether` 随即注册出 `eth1`，
  属 HiLink 网卡模式，**免 PPP/QMI 拨号**。
- **可以先不插模块**：`r1c-apply` 会照样建好接口并纳入切换策略（处于待命），
  之后插上由 hotplug 自动接管，**不必重跑一次 apply**。
- ⚠️ 切换是 **failover，不是负载均衡**：WireGuard 是单条 UDP 流，一旦在两条上行间均衡，
  源 IP 会来回跳、Hub 端看到的 endpoint 反复变化，表现为隧道每隔几分钟重建一次、PLC 间歇不通。
- 现场验证：`mwan3 status`（主用应显示 online，其余为备用）。

> 完整参数列表与逐条注释见 [`files/etc/r1c/site.conf`](files/etc/r1c/site.conf)。

---

## 6. 隧道断了怎么办（应急通道）

现场最常见的故障是：**换了手机热点或改了热点密码 → STA 连不上 → 隧道断 → Hub 管理页连不上网关 → 改不了 WiFi → 死锁。**

链路里有两道自救设计：

1. **5G 应急 AP** —— 5G 射频（radio0）常开一个 AP，SSID / 密码为出厂固定值
   （见 [`files/etc/uci-defaults/92-r1c-emergency-ap.sh`](files/etc/uci-defaults/92-r1c-emergency-ap.sh) 的 `AP_SSID` / `AP_KEY`）。
   手机或笔记本直接连上它 → 拿到 LAN 网段地址（DHCP 池刻意收窄到 `.240–.249`，避开 PLC 常用地址）。
2. **本地管理页** —— 浏览器打开 `http://<LAN 地址>/cgi-bin/r1c`，5 个页签：

   | 页签 | 作用 |
   | --- | --- |
   | **状态** | WAN / VPN / PLC 设备体检（ICMP + TCP/102） |
   | **WiFi** | 改 STA 的 SSID 与密码（救上面那个死循环） |
   | **站点** | 编辑 `site.conf` 并执行 apply |
   | **日志** | 看服务日志 |
   | **诊断** | 跑 `r1c-diagnose` 出报告 |

   同一个页面也挂在 LuCI 后台菜单「**R1C 工业网关**」里（`admin/r1c`）。

> 之所以放在 5G 而不是 2.4G：2.4G（radio1）要留给 STA 连手机热点，两块射频独立互不干扰，
> 且现场干扰几乎全在 2.4G。做完应急操作若要求零无线暴露：
> `uci set wireless.r1c_ap.disabled=1; uci commit wireless; wifi reload`

---

## 7. 命令行工具

| 命令 | 作用 |
| --- | --- |
| `r1c-status` | 一屏看清 Site ID / WAN / VPN / PLC 与健康状态，支持 JSON 输出供采集 |
| `r1c-apply` | 把 `site.conf` 应用到 UCI（`--check` 只校验，`--dry-run` 只打印） |
| `r1c-diagnose` | 生成诊断报告到 `/tmp/r1c-diagnose-*.txt`，只读、不改配置、不重启 |
| `r1c-test-plc` | 对 `PLC_DEVICES` 列表做连通性测试，**禁止任何写操作** |
| `r1c-wg-watchdog` | 单次执行的域名重解析，**不要手动跑**，由服务主循环按 `CHECK_INTERVAL`（默认 30s）调用 |

服务本体是 `procd` 管理的主循环，崩溃会自动重启：

```sh
/etc/init.d/r1c-gateway {start|stop|restart|status}    # 出厂已 enable
logread -e r1c                                          # 看日志
```

---

## 8. 目录结构

```
openwrt-r1c-gateway/
├── configs/r1c-gateway.config      # kconfig 配置（注意：=y 行尾不能带注释，会被静默忽略）
├── files/                          # rootfs overlay —— 新文件必须在 Makefile install 段登记
│   ├── etc/r1c/site.conf           #   现场配置唯一真相源（占位值）
│   ├── etc/init.d/r1c-gateway      #   procd 主循环服务
│   ├── etc/uci-defaults/           #   90 STA 模板 / 91 LuCI 中文 / 92 应急 AP
│   ├── lib/upgrade/keep.d/         #   升级保留 /etc/r1c/
│   ├── usr/bin/                    #   r1c-status / apply / diagnose / test-plc / wg-watchdog
│   ├── usr/share/luci/menu.d/      #   LuCI 菜单入口
│   └── www/                        #   cgi-bin/r1c（应急页）+ luci-static JS view
├── package/r1c-gateway/            # 自研包 Makefile（files/ 由 diy 脚本同步进来）
├── diy-part1.sh / diy-part2.sh     # 构建钩子（feeds 前后）
├── diy-part2.d/10-r1c-gateway.sh   # 注入自研包、补执行位、兜底注入中文语言包
├── scripts/                        # make-release / check-size / backup-mtd / flash-over-ssh 等
├── patches/                        # 源码补丁（当前为空）
├── source.commit                   # 锁定的上游 commit
└── .github/workflows/build-r1c.yml # 云端构建与自动发布
```

配套的 **Hub 服务端管理程序**（多站点看板、批量下发配置、快照回滚、巡检）是独立组件，
**不在本仓库内**，需另行部署。

---

## 9. 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/HARDWARE.md](docs/HARDWARE.md) | 硬件规格确认：分区表、GPIO/LED、交换机布局、Flash 预算实测数据 |
| [docs/BUILD.md](docs/BUILD.md) | 构建体系：为何弃用 lede 源码树、为什么要锁 commit、目录形态 |
| [docs/NETWORK.md](docs/NETWORK.md) | 网络架构：网段为何不进固件、配置层次、role 模式差异 |
| [docs/VPN-COMPATIBILITY.md](docs/VPN-COMPATIBILITY.md) | WireGuard / ZeroTier / Tailscale / cloudflared 在 mt7620 上的选型依据（含实测体积数据） |
| [docs/FLASH-RUNBOOK.md](docs/FLASH-RUNBOOK.md) | 逐步骤刷机作业手册（开工前检查表 + 三段式流程） |
| [docs/FIRST-BOOT.md](docs/FIRST-BOOT.md) | 首次上电会发生什么，以及"看起来没起来"的排查思路 |

---

## 10. 已知限制

- **sysupgrade 后首次上线约 7 分钟**，期间不可打扰。
- **无硬件加密引擎**（MT7620A 无 crypto 节点），WireGuard 全部由 580MHz 单核软算，
  吞吐有限 —— 不要再叠加第二层加密隧道。
- **HTTPS(443) 默认不可用**：固件未编入 `px5g` / `openssl`，uhttpd 无法自签证书。
  管理后台走 HTTP(80)；隧道本身已是 ChaCha20 加密，明文只在隧道与现场 LAN 内。
- `HOSTNAME` 当前不会随 `site.conf` 自动应用；`r1c-apply` 不负责 WiFi 的连接重试策略。

### FAQ

**Q：能 ping 通 R1C，但打不开后台？**
A：`firewall.vpn` 区的 input 默认是 REJECT，只放行 SSH(22) 与 ICMP。要开管理页请设 `VPN_HTTP_ACCESS=allow`
（前提是已 `passwd root`）。注意这只影响**访问 R1C 自己**；访问网段内**其他设备**（PLC、HMI）走的是 forward 链，
那里没有任何端口限制。

**Q：为什么握手正常但 ping 不通 PLC？**
A：多半是多站点**网段撞车** —— 同一个 CIDR 被配给了两个 peer，WireGuard 会静默丢掉最后一个。
同一 CIDR 只能属于一个 peer。

---

## 11. 许可证

固件部分基于 [OpenWrt](https://github.com/openwrt/openwrt)（GPL-2.0-only）。
本仓库的自研脚本与工具（`files/`、`package/r1c-gateway/`、`scripts/`）同为 GPL-2.0-only。
