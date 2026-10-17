# 现场改网段 / 改网关地址作业卡

> 场景：客户现场的 PLC 网段或 R1C 的 LAN 地址要变（换 PLC、并入别的产线、地址冲突等）。
> 设计原理见 [NETWORK.md](NETWORK.md)；首次装机见 [FIRST-BOOT.md](FIRST-BOOT.md)。
> **一句话：三处必须同步 —— R1C 的 site.conf、Hub 上的 peer、工程师 PC 的 AllowedIPs。**

---

## 0. 先记住这三条（踩过的坑都在这儿）

| # | 结论 | 不改会怎样 |
| - | --- | --- |
| 1 | **Hub 必须同步** `lan_ip` 和 `extra_allowed`（PLC 网段） | Hub 显示**在线**（握手正常），但 ping 不通 PLC、「远程配置/远程监控」全挂 |
| 2 | Hub 的远程功能走的是 **lan_ip，不是隧道 IP** | lan_ip 一变，Hub 立刻够不着设备 |
| 3 | **隧道 IP（`10.0.1.x`）、密钥、PSK 都不用动** | 改的是 LAN 侧，VPN 侧无感；千万别去重新生成密钥 |

> `wg syncconf` 只管握手，**不会自动补路由**。网段不同步时包到了 Hub 也没有路走。

---

## 1. 改动清单（先抄下来再动手）

| 位置 | 字段 | 例 | 备注 |
| --- | --- | --- | --- |
| R1C `/etc/r1c/site.conf` | `PLC_NETWORK` | `172.21.12.0/24` | 现场 PLC 网段 |
| 同上 | `PLC_LOCAL_IP` | `172.21.12.254` | R1C 在 PLC 网段里占的地址（host 模式） |
| 同上 | `PLC_GATEWAY` | `172.21.12.1` | gateway 模式才有意义 |
| 同上 | `PLC_DEVICES` | `S7-PLC\|172.21.12.181\|s7\|…` | 每台设备的 IP 要跟着改，否则状态页一直显示 down |
| Hub → 站点编辑 | `lan_ip` | `172.21.12.254` | = `PLC_LOCAL_IP` |
| Hub → 站点编辑 | `extra_allowed` | `172.21.12.0/24` | = `PLC_NETWORK` |
| 工程师 PC `.conf` | `AllowedIPs` | `10.0.1.0/24, 172.16.0.0/12` | 新网段在 `172.16~172.31` 内**就不用改** |

---

## 2. 两条改法（**首选 A**）

### A. 从 Hub 下发（推荐 —— 不会把自己锁在外面）

1. Hub 网页 → 站点 → **远程配置**
2. 改「PLC 网段 / R1C 现场地址 / PLC 设备清单」
3. 点「下发到网关并应用」
4. 等待 30–60 秒（网络重启，隧道会抖一下后自愈）

✅ Hub 会自动回写 peer 的 `lan_ip` 与 `extra_allowed`（`update_peer_from_conf`），**不用再手工改 Hub**。

### B. 客户在 R1C 本地改（现场没有 Hub 权限时）

1. 改 `/etc/r1c/site.conf`（或本地页 `http://<lan-ip>/cgi-bin/r1c`）→ 执行 `r1c-apply`
2. **设备改完那一刻，Hub 就够不着它了**（lan_ip 还是旧的）
3. 到 Hub 上手工改该 peer 的 `lan_ip` 和 `extra_allowed` → 保存

⚠️ 顺序不能反：**先在 Hub 改 lan_ip 会导致连不上设备**（此时设备还是老地址）。
⚠️ 巡检**不会**自动把设备上的新网段同步回 Hub（巡检只写 monitor.json，从不回写 peers.json）。

---

## 3. 改完必须验这四项

| # | 验什么 | 怎么验 | 通过判据 |
| - | --- | --- | --- |
| 1 | R1C 自身 | 设备上 `r1c-status --json` | `lan_applied` = 新地址 |
| 2 | Hub 路由 | Hub 上 `ip route \| grep <新网段>` | 有 `dev wg0` 的路由 |
| 3 | 端到端 | Hub 上 `ping <新 PLC 网段地址>` | 通；`curl http://<lan_ip>/` = 200 |
| 4 | 远程管理 | Hub → 远程配置页 | 200，能读到 site.conf |

PLC 侧真机验：`r1c-test-plc` 或 TIA 手动填 IP 连接（**广播搜索在 L3 隧道里不通，必须手动填 IP**）。

---

## 4. 两个坑（会直接卡住）

### 4.1 网段撞车 → Hub 拒绝保存

同一 CIDR 在服务端只能属于一个 peer。若新网段跟别的站点重复，Hub 会拦下来（WG 不会报错，只会**静默保留最后一个**，被抢的那个表现为"握手正常但 ping 不到 PLC"）。

解法：启用 Hub 的**网段映射**（虚拟 `10.66.N.0`），详见 Hub 的站点编辑页 / `wg-hub/docs/`。

### 4.2 DHCP 池盖住 PLC 地址

R1C 的 LAN DHCP 池默认已收窄为 `.240–.249`，就是为了避免把 `172.21.x.181` 这类 PLC 地址分给别人。
**换网段后如果 PLC 落在 .240–.249 里**，务必调整：

```sh
uci set dhcp.lan.start=240   # 按需改
uci set dhcp.lan.limit=10
uci commit dhcp
/etc/init.d/dnsmasq restart
```

---

## 5. 回滚

Hub 的每次下发都会**自动存快照**（`site.conf.bak.<时间戳>`），可 diff / 一键回滚：
Hub → 站点 → 快照历史 → 选一个 → 回滚。

设备本地改的，也有 `cp /etc/r1c/site.conf.bak-factory /etc/r1c/site.conf && r1c-apply` 兜底。
