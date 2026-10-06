# R1C 刷机作业指导书（Runbook）

> 逐步执行的作业手册。设计原理与"为什么这么做"见 [FIRST-BOOT.md](FIRST-BOOT.md)。
> 目标固件：`2026.09.24-0937`（kernel 6.6.156，sysupgrade 10624 KiB / 上限 15872 KiB）。
> 分工：**A、B 两段你做，C 段之后助手做**。全程约 25–35 分钟。

---

## 0. 开工前检查表（逐项打勾，缺一项就停）

| # | 检查项 | 判据 | ✅ |
| --- | --- | --- | --- |
| 1 | breed 已刷入且可进 | 断电按 Reset 上电能打开 192.168.1.1 | ☐ |
| 2 | 分区备份已存到**电脑**（非浏览器下载目录） | 有 Bootloader / Factory / Bdata / OS1 四个文件 | ☐ |
| 3 | breed「固件启动设置 → 类型」= **小米 MINI** | 页面回显，见 §1.3 | ☐ |
| 4 | 两个镜像已在本机 | `firmware/` 下，sha256 已 `sha256sum -c` 通过 | ☐ |
| 5 | 网线一根 + 电脑有**有线网口** | — | ☐ |
| 6 | R1C 供电稳定，刷机过程中**不断电** | — | ☐ |

> ⚠️ 第 2 项最重要：`Factory` 存的是无线 EEPROM 与 MAC，丢了无线永久报废，且**无法从其他机器复制**。
> ⚠️ 第 3 项错会表现为"能刷进去但起不来"，是最常见的翻车点。

---

## A. 刷入 initramfs（你操作，约 5 分钟）

这一步把系统加载到 **RAM** 运行，**不写 Flash**，断电即回 breed，零风险。

### A1. 进入 breed

1. 路由器**断电**，拔掉 WAN 口网线（留 LAN 口后用）
2. 用牙签**顶住 Reset**不放
3. 接通电源，等 **3–5 秒**，指示灯开始闪烁后松开
4. 网线接电脑网口 ↔ 路由器 **LAN 口**（两个 LAN 口任取其一，**不要接 WAN**）
5. 浏览器打开 **http://192.168.1.1**

看到 breed Web 恢复控制台 = 成功。打不开看 §F 故障表第 1 行。

### A2. 设置电脑静态 IP

breed 不一定开 DHCP。**只改有线网卡**，别动 Wi-Fi。

```bat
:: 先查有线网卡名称
netsh interface show interface

:: 假设名称是"以太网"（按实际替换）
netsh interface ip set address name="以太网" static 192.168.1.2 255.255.255.0
```

图形路径：控制面板 → 网络和共享中心 → 更改适配器设置 → 右键"以太网" →
属性 → Internet 协议版本 4 → 使用下面的 IP 地址 → `192.168.1.2` / `255.255.255.0`，网关留空。

### A3. 核对闪存布局（关键）

breed 界面：**固件启动设置** → **类型** → 必须是 **小米 MINI**。

与 OpenWrt DTS 的分区表对应关系（必须一致）：

| 分区 | 起始 | 大小 |
| --- | --- | --- |
| `u-boot` | 0x000000 | 0x30000 |
| `u-boot-env` | 0x030000 | 0x10000 |
| `factory` | 0x040000 | 0x10000 |
| **`firmware`** | **0x050000** | **0xf80000** |

选错 → 刷完起不来，串口停在 `Bad magic` / 找不到 rootfs。改完记得**保存**。

### A4. 上传镜像

breed → **固件更新** → 「固件」选择文件：

```
firmware/r1c-gateway-2026.09.24-0937-initramfs-kernel.bin      (10362804 B)
```

点击上传 → 等待自动重启，**全程不要断电**。

### A5. 判读

| 现象 | 判读 |
| --- | --- |
| 红灯闪烁后转常亮，电脑能拿到地址 | ✅ 起来了 |
| 串口出现 `procd:` / `initramfs` 输出 | ✅ 起来了 |
| 停在 breed / 反复重启回 breed | ❌ A3 布局不对，回 A3 |
| 串口 `Bad magic` / 找不到 rootfs | ❌ 分区不匹配，回 A3 |
| 串口 `kernel panic - not syncing` | ❌ 取完整串口日志再分析 |

---

## B. 建立 SSH 通道（你操作，约 1 分钟）

1. 网线保持接 **LAN 口**
2. 电脑 IP 保持 `192.168.1.2 / 255.255.255.0`
3. 确认能 ping 通：`ping 192.168.1.1`
4. 回助手一句「可以了」

> 地址说明：breed 与 OpenWrt 的 LAN **都是 192.168.1.1**。电脑若提示 IP 冲突属正常。
> 出厂 `AUTO_APPLY=0`，LAN **不会**变成 192.168.10.1。若你拿到的是 192.168.10.x，
> 说明刷的是旧版固件（2026.09.24-0033 及更早），请重刷新版。

---

## C. 只读探测（助手执行，约 2 分钟）

```sh
./scripts/flash-over-ssh.sh probe
```

逐项判据：

| 项 | 期望 | 不合格怎么办 |
| --- | --- | --- |
| `board_name` | `xiaomi,miwifi-mini` | sysupgrade 会拒绝，先查分区表 |
| `/proc/mtd` 有 `firmware` ≈ 15.5M | 与上表一致 | 回 A3 改 breed 布局 |
| `factory` 分区 | 存在且 read-only | 停，先用备份恢复 |
| MAC @ factory+0x28 | 真实地址，非全 0 / 非 `00:11:22:33:44:55` | 停，恢复 Factory 备份 |
| 运行模式 | `RAM / initramfs` | — |
| `free` | ≥ 40 MB（镜像 10 MB 放 /tmp） | 重启重试 |

---

## D. Phase 2 验收（助手执行，约 5 分钟）

```sh
./scripts/flash-over-ssh.sh verify
```

判据：

| # | 检查 | 期望 |
| --- | --- | --- |
| 1 | `r1c-apply` `r1c-status` `r1c-diagnose` `r1c-test-plc` | 四个都在，缺任一 → 停，固件有问题 |
| 2 | `r1c-apply --check` | **退出码 1**，提示 `SITE_ID 仍是出厂占位值 SITE000，拒绝应用`。<br>若返回 0 → 说明不是新版固件，重刷 |
| 3 | `swconfig list` | 出现 `switch0`（**非 DSA**） |
| 4 | `iw list` | 有 2.4G（rt2800）与 5G（mt76x2）两个 phy |
| 5 | `ls /sys/class/leds/` | 蓝 / 黄 / 红三色 |
| 6 | `lsusb` | 插 U 盘后出现设备 |
| 7 | `r1c-status` | Site/PLC/VPN 显示占位或 UNSET 属正常 |

**五项全过才准固化。**

---

## E. 固化到 Flash（助手执行，约 5 分钟）

### E1. 先看干跑清单（不写设备）

```sh
./scripts/flash-over-ssh.sh flash \
  --image firmware/r1c-gateway-2026.09.24-0937-sysupgrade.bin
```

输出里确认三件事：体积 ≤ 15872 KiB、板型匹配、将执行的命令是 `sysupgrade -n`。

### E2. 真正写入

```sh
./scripts/flash-over-ssh.sh flash \
  --image firmware/r1c-gateway-2026.09.24-0937-sysupgrade.bin --apply
```

脚本内部：上传 → **两端 sha256 比对（不一致立即中止）** → `sysupgrade -n` →
等重启上线（最多 180s）→ 回读版本。

> 脚本只调用 `sysupgrade`（仅写 `firmware` 分区），不含任何 `mtd write`。
> sysupgrade 若因板型校验自行拒绝，**不得加 `-F` 强刷** —— 先回 A3 查布局。

### E3. 备用路径（sysupgrade 走不通时）

断电 → 按 Reset 上电 → 进 breed → 固件更新 → 选 **sysupgrade.bin**。
效果相同，但优先走 E2（有校验、有回读）。

---

## F. 固化后验证（助手执行，约 3 分钟）

```sh
./scripts/flash-over-ssh.sh probe
```

| 项 | 期望 |
| --- | --- |
| 运行模式 | **Flash / 固化系统**（不再是 initramfs） |
| `mount` 的 `/` | overlay（不是 tmpfs/ramfs） |
| `/proc/mtd` | 与 C 段一致 |
| 四个 `r1c-*` 工具 | 全在 |
| `r1c-apply --check` | 仍返回 1（占位值未填） |

最后手工做两件事：

```sh
passwd                 # 设 root 密码（LuCI 首次登录也会要求）
```

断电重启一次，确认**不再回 breed**而是直接进系统 = 固化成功。

---

## G. 故障处理矩阵

| # | 现象 | 原因 | 动作 |
| --- | --- | --- | --- |
| 1 | 打不开 192.168.1.1 | 没进 breed / 网线在 WAN 口 / 电脑 IP 不对 | 重做 A1；确认接 LAN 口；IP 改 192.168.1.2 |
| 2 | 刷完停在 breed | 闪存布局不匹配 | A3 改成「小米 MINI」并重刷 |
| 3 | 串口 `Bad magic` | 同上 | 同上 |
| 4 | `kernel panic` | 内核/设备树问题 | 取完整串口日志分析 |
| 5 | MAC 全 0 或假地址 | factory 分区损坏 | **停**，用备份恢复 Factory |
| 6 | 无线信号差 / 搜不到 5G | factory EEPROM 异常 | 恢复 Factory 备份 |
| 7 | SSH 连不上 | 设备未启动完成 / IP 冲突 | 等 30s 重试；确认本机 IP |
| 8 | sysupgrade 拒绝刷入 | 板型不匹配 | 查 A3，**不要 `-F`** |
| 9 | 固化后仍回 breed | 没写进去 / 布局不一致 | 走 E3 备用路径；查 A3 |
| 10 | breed 也进不去 | bootloader 损坏 | TTL 串口 / CH341A 编程器救砖 |

串口参数：**TTL 3.3V，115200 8N1**。

---

## H. 时间预估与分工汇总

| 段 | 内容 | 执行者 | 时长 |
| --- | --- | --- | --- |
| 0 | 检查表 | 你 | 3 min |
| A | 刷 initramfs | **你**（唯一图形动作） | 5 min |
| B | 建 SSH 通道 | 你 | 1 min |
| C | 只读探测 | 助手 | 2 min |
| D | Phase 2 验收 | 助手 | 5 min |
| E | 固化 sysupgrade | 助手 | 5 min |
| F | 固化后验证 | 助手 | 3 min |

---

## I. 红线复述

- 只写 `firmware` 分区；`factory` / `Bdata` / `u-boot` / `u-boot-env` **永不写入**
- 不改分区表、不动 U-Boot / breed
- 不使用 `mtd write`；不用 `sysupgrade -F` 强刷
- 刷机过程不断电，尤其 E 段

---

## 固化成功后：配置现场参数

```sh
vi /etc/r1c/site.conf     # 填 SITE_ID / PLC_NETWORK / VPN_ADDR / WireGuard 对端
r1c-apply --dry-run        # 看将要下发什么
r1c-apply                  # 确认无误后应用
r1c-diagnose               # 自检
```

私钥放 `/etc/r1c/wg-private.key`（site.conf 里只存路径，不存密钥）。
详细参数见 [NETWORK.md](NETWORK.md)。
