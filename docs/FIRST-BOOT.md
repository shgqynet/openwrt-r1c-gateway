# 首次装机与验证（breed 路线）

> 适用：已刷入 **breed**（`breed-mt7620-xiaomi-mini.bin`）并完成备份的 R1C。
> 本文所有命令**由你在设备上/电脑上手写执行**。本项目红线（需求 §64）禁止
> 自动化执行 `mtd write` / `sysupgrade`，本文档不提供任何一键刷机脚本。

---

## 0. 刷之前：两个必须先确认的点

### 0.1 breed 的「固件启动设置 → 类型」必须是「小米 MINI」

这是**最容易翻车的一步**。breed 的这个选项决定它认定的闪存布局，
与 OpenWrt DTS 里写死的分区表必须一致：

| OpenWrt DTS（本设备） | 起始 | 大小 |
| --- | --- | --- |
| `u-boot` | 0x000000 | 0x30000 |
| `u-boot-env` | 0x030000 | 0x10000 |
| `factory` | 0x040000 | 0x10000 |
| **`firmware`** | **0x050000** | **0xf80000** |

布局不匹配时典型症状：刷完**能刷进去但起不来**，串口停在
`Bad magic`/找不到 rootfs，或 kernel panic。此时不必怀疑固件，先查这一项。

### 0.2 确认备份齐全

刷机前必须已保存（breed 的「固件备份」页面逐个点一遍即可）：

| 分区 | 为什么必须有 |
| --- | --- |
| `Bootloader` | 救砖用 |
| `Config` / `Bdata` | 原厂 SN、区域等板级数据 |
| **`Factory`** | **无线 EEPROM + MAC（偏移 0x28）。丢了无线就永久废了** |
| `OS1` | 原厂固件，回退用 |

建议把备份文件**再复制一份到电脑**，别只留在浏览器下载目录。

---

## 1. 进入 breed Web 恢复控制台

1. 路由器断电
2. 顶住 **Reset** 不放
3. 接通电源，等约 3–5 秒，指示灯开始闪烁后松开
4. 电脑网口接路由器 **LAN 口**
5. 电脑 IP 设为静态 `192.168.1.2 / 255.255.255.0`（breed 不一定有 DHCP）
6. 浏览器打开 **http://192.168.1.1**

看到 breed Web 恢复控制台即成功。

---

## 2. 第一步先刷 initramfs（可逆，强烈建议）

**不要一上来就刷 sysupgrade。** 先用 `initramfs-kernel.bin`：

- 它整体在 **RAM 里运行，不写入 Flash**
- 能启动 → 说明内核、驱动、分区表、设备树全部正确
- **断电重启即回到 breed**，零风险
- 万一不启动，也只是重启的事，不会变砖

操作：breed →「固件更新」→「固件」选中
`r1c-gateway-*-initramfs-kernel.bin` → 上传 → 等待自动重启。

### 2.1 启动成功/失败的判读

| 现象 | 判读 |
| --- | --- |
| 红灯闪烁后转红灯常亮，电脑能拿到 DHCP | ✅ 起来了 |
| 串口有 `procd:` / `initramfs` 输出 | ✅ 起来了 |
| 停在 breed 界面 / 反复重启回 breed | ❌ 多半是 0.1 的布局不对 |
| 串口 `Bad magic` / 找不到 rootfs | ❌ 分区不匹配，检查 0.1 |
| 串口 `kernel panic - not syncing` | ❌ 取完整串口日志再分析 |

---

## 3. 起来之后：Phase 2 验证清单（需求 §55）

默认 LAN 地址为 **192.168.1.1**（出厂 `AUTO_APPLY=0`，不会改地址）。
首次登录 LuCI 无密码，按提示设置一个。

### 3.1 基础网络

```sh
ssh root@192.168.1.1
r1c-status          # 应显示 Site/PLC/VPN 均为占位或 UNSET，属正常
r1c-diagnose        # 全量自检
```

### 3.2 分区表核对（关键）

```sh
cat /proc/mtd
```

应能看到 `firmware`（约 15.5M）、`factory`、`Bdata` 等分区。
**`factory` 必须是 read-only**，且能读出 MAC：

```sh
hexdump -C /dev/mtd2 -s 0x28 -n 6    # 分区号以 cat /proc/mtd 实际为准
```

### 3.3 无线

```sh
iw list | grep -E "Band|phy"     # 应看到 2.4G(rt2800) 与 5G(mt76x2)
uci show wireless | grep -c wifi-iface
```

MAC 若全为 `00:11:22:33:44:55` 之类的假地址，说明 `factory` 分区有问题——
**这时该用备份恢复，而不是继续往下走**。

### 3.4 交换机 / LED / USB

```sh
swconfig list                       # 应为 swconfig（非 DSA）
swconfig dev switch0 show | head
ls /sys/class/leds/                 # 蓝/黄/红三色
lsusb                               # 插 U 盘后应出现设备
```

### 3.5 工具是否都在

```sh
which r1c-apply r1c-status r1c-diagnose r1c-test-plc
```

四个都必须有。缺任何一个都说明固件有问题，不要继续。

### 3.6 验证占位配置确实不会生效

```sh
r1c-apply --check
```

**期望：退出码 1，提示 `SITE_ID 仍是出厂占位值 SITE000，拒绝应用`。**
如果它居然通过了，说明刷的不是最新固件（见第 5 节）。

---

## 4. 固化：刷入 sysupgrade

验证全部通过后，才做这一步。两种方式：

**A. 在跑起来的 OpenWrt 里 sysupgrade（推荐）**

```sh
sysupgrade -n /tmp/r1c-gateway-*-sysupgrade.bin
```

`-n` 表示不保留配置。首次装机建议加 `-n`，避免 initramfs 期间产生的
临时配置被带进固化系统。

**B. 回 breed 刷 sysupgrade**

断电 → 按住 reset 上电 → breed → 固件更新 → 选 `sysupgrade.bin`。

固化后重启，再次确认 `cat /proc/mtd` 与 3.5 的工具清单。

---

## 5. 关于固件版本

| Release | 状态 |
| --- | --- |
| `2026.09.24-0033` 及更早 | ⚠️ 占位配置会开机自动生效，LAN 会变成 `192.168.10.1` |
| `AUTO_APPLY=0` 之后的版本 | ✅ 出厂零配置，LAN 保持 `192.168.1.1`，`r1c-apply --check` 会拒绝占位值 |

**建议直接用新版本刷。** 若手里只有旧版本，记住 LAN 是 `192.168.10.1`，
不要用 `192.168.1.1` 去访问然后误判刷机失败。

---

## 6. 出问题时

| 情况 | 处理 |
| --- | --- |
| 刷完起不来 | 回 breed（按住 reset 上电），检查 0.1 布局 |
| 无线信号差 / MAC 异常 | 用备份恢复 `Factory` 分区 |
| 想回原厂 | breed 里刷回备份的 `OS1` + `Bootloader` |
| breed 也进不去 | 只能 TTL 串口 / CH341A 编程器救砖 |

串口参数：**TTL 3.3V，115200 8N1**。
