# HARDWARE.md — Xiaomi MiWiFi Mini (R1C) 硬件确认

> 项目：R1C Industrial Remote Gateway
> 阶段：Phase 1（硬件确认）— **本阶段不刷机、不改 U-Boot、不动分区**
> 数据获取方式：OpenWrt 官方源码 DTS / OpenWrt 官方下载站实际镜像字节数 / OpenWrt TOH + Techdata
> 未在真机上电验证的项目统一标记 `[PENDING]`，**不作为结论使用**。

---

## 1. 设备标识

| 项目 | 值 | 来源 |
| --- | --- | --- |
| 型号 | Xiaomi MiWiFi Mini（市场/固件代号 **R1CM**） | TOH |
| OpenWrt compatible string | `xiaomi,miwifi-mini`, `ralink,mt7620a-soc` | DTS |
| OpenWrt 设备 profile | `xiaomi_miwifi-mini` | mt7620.mk |
| Target / Subtarget | `ramips` / `mt7620` | Techdata |
| 包架构 | **mipsel_24kc** | Techdata |
| 官方支持版本 | 24.10.5（Supported Current Rel）；自 15.05 起支持 | TOH |
| OpenWrt 源码 DTS | `target/linux/ramips/dts/mt7620a_xiaomi_miwifi-mini.dts` | openwrt main |

---

## 2. 核心硬件

| 项目 | 规格 |
| --- | --- |
| SoC | MediaTek **MT7620A**，MIPS **24KEc V5.0**，580 MHz（OpenWrt 日志亦见 620MHz 打印） |
| CPU 类型 | `24kc` → 包架构 `mipsel_24kc`（**小端、无硬件 FPU，soft-float**） |
| RAM | **128 MiB DDR2**（Samsung K4T1G164QG-BCF7） |
| Flash | **16 MiB SPI NOR**（Winbond W25Q128FVSIG / W25Q128BV） |
| 2.4GHz | SoC 内置 **MT7620A** 802.11b/g/n，驱动 `rt2800`（`kmod-rt2800-soc`），EEPROM 取自 `factory` |
| 5GHz | 独立 PCIe **MT7612EN** 802.11a/n/ac（仅接线 5GHz），驱动 `mt76`（`kmod-mt76x2`），EEPROM 取自 `factory+0x8000` |
| Ethernet | **3 × 10/100 Mbps**（无千兆物理口），SoC 内置 switch，支持 VLAN |
| USB | **1 × USB 2.0**（EHCI + OHCI 均已在 DTS 中 enable） |
| 串口 | TTL 3.3V，**115200 8N1**（`console=ttyS0,115200`） |
| 按钮 | 1 × Reset |
| LED | 3 ×（蓝/黄/红）+ WAN/LAN1/LAN2 |
| 供电 | 12V DC 1.0A，功耗 1.5–2.1W |
| 硬件加密引擎 | DTS 中**无 crypto/AES 节点** → **无硬件加解密加速**，VPN 加密全部由 CPU 软算 |

### 2.1 硬件加密缺失的工程含义（重要）

- WireGuard 使用的 ChaCha20-Poly1305 为纯软件实现，580MHz 单核 MIPS 上吞吐有限。
- `[PENDING]` 实测项：VPN 吞吐、PLC 通信并发下的 CPU 占用。
- 结论先行的设计约束：**不要在 R1C 上叠加多层加密隧道**（如 WireGuard 之上再套 TLS 隧道）。

---

## 3. Flash 分区表（OpenWrt 视图，来自官方 DTS）

| 分区 | 起始 | 大小 | 属性 | 用途 |
| --- | --- | --- | --- | --- |
| `u-boot` | 0x000000 | 0x30000 (192K) | **read-only** | 原厂 U-Boot，**禁止改写** |
| `u-boot-env` | 0x030000 | 0x10000 (64K) | 可写 | U-Boot 环境变量 |
| `factory` | 0x040000 | 0x10000 (64K) | **read-only** | 无线 EEPROM/校准数据 + MAC（offset 0x28） |
| `firmware` | 0x050000 | **0xf80000 (15.5 MiB)** | 可写 | kernel + rootfs（squashfs）+ overlay |
| `crash` | 0xfd0000 | 0x10000 (64K) | 可写 | 崩溃日志 |
| `reserved` | 0xfe0000 | 0x10000 (64K) | **read-only** | 保留 |
| `Bdata` | 0xff0000 | 0x10000 (64K) | 可写 | 板级数据（含原厂 SN/区域等） |

`factory` 分区内的 nvmem 布局（官方 DTS `nvmem-layout`）：

| 名称 | offset | 长度 | 用途 |
| --- | --- | --- | --- |
| `eeprom@0` | 0x0 | 0x200 | 2.4GHz（wmac）校准数据 |
| `eeprom@8000` | 0x8000 | 0x200 | 5GHz（mt76）校准数据 |
| `macaddr@28` | 0x28 | 0x6 | 以太网 MAC |

### 3.1 原厂固件视图（刷机前 `cat /proc/mtd` 常见结果）

```
mtd0  ALL          16MB
mtd1  Bootloader   0x30000
mtd2  Config       0x10000
mtd3  Factory      0x10000
mtd4  OS1          0xc80000     <- OpenWrt 实际写入目标
mtd5  rootfs
mtd6  OS2          0x200000
mtd7  overlay
mtd8  crash
mtd9  reserved
mtd10 Bdata
```

> 注意：OpenWrt 安装说明要求写入 **OS1**（不是 `firmware`）。原厂 Bootloader 会在 OS1 启动失败时回退 OS2。
> **本项目第一阶段不执行任何 mtd 写操作。**

---

## 4. Flash 容量预算（实测数据，非估算）

| 项目 | 实测值 | 来源 |
| --- | --- | --- |
| `firmware` 分区容量 | 15872 KiB（15.5 MiB） | `mt7620.mk: IMAGE_SIZE := 15872k` |
| 官方 24.10.5 sysupgrade 镜像 | **6528 KiB（6.38 MiB）** | HTTP Content-Length 实测 |
| 官方 24.10.5 initramfs-kernel 镜像 | **6295 KiB（6.15 MiB）** | HTTP Content-Length 实测 |
| 官方是否提供 factory 镜像 | **否（HTTP 404）** | 实测 |
| **剩余可分配预算** | **约 9.0 MiB** | 15872 − 6528 |

**预算规则（写进 build.sh 的固件大小检查）：**

| 阈值 | 判定 |
| --- | --- |
| 镜像 ≤ 12 MiB | OK |
| 12 MiB < 镜像 ≤ 15.0 MiB | WARN（overlay 空间不足，禁止再加包） |
| 镜像 > 15.0 MiB（或 > IMAGE_SIZE 15872k） | **BUILD FAILED** |

---

## 5. GPIO / LED / Button（来自官方 DTS，逐字核对）

```dts
leds {
    led_blue:   blue   { gpios = <&gpio1 0 GPIO_ACTIVE_LOW>; };  /* 状态蓝 */
    led_yellow: yellow { gpios = <&gpio1 2 GPIO_ACTIVE_LOW>; };  /* 状态黄 */
    led_red:    red    { gpios = <&gpio1 5 GPIO_ACTIVE_LOW>; };  /* 状态红 */
    wan  { gpios = <&gpio2 4 GPIO_ACTIVE_LOW>; };
    lan1 { gpios = <&gpio2 1 GPIO_ACTIVE_LOW>; };
    lan2 { gpios = <&gpio2 0 GPIO_ACTIVE_LOW>; };
};
keys {
    reset { gpios = <&gpio1 6 GPIO_ACTIVE_HIGH>; linux,code = <KEY_RESTART>; };
};
aliases {
    led-boot = &led_yellow;  led-failsafe = &led_red;
    led-running = &led_blue; led-upgrade  = &led_blue;
};
```

| LED | sysfs 名称 | GPIO | 有效电平 |
| --- | --- | --- | --- |
| 蓝 | `blue:status` | gpio1.0 | 低电平点亮 |
| 黄 | `yellow:status` | gpio1.2 | 低电平点亮 |
| 红 | `red:status` | gpio1.5 | 低电平点亮 |
| WAN | `green:wan` | gpio2.4 | 低电平点亮 |
| LAN1 | `green:lan1` | gpio2.1 | 低电平点亮 |
| LAN2 | `green:lan2` | gpio2.0 | 低电平点亮 |

**对需求 §35/§36 的修正**：需求中提到的"紫"色在 DTS 中并不存在，官方定义为 **blue**（原厂固件混合出的紫色靠 PWM 混色，OpenWrt 只做单色开关）。
本项目 LED 方案按此三色重新映射：

| 网关状态 | LED 表现（方案，`[PENDING]` 真机校色） |
| --- | --- |
| Boot | 黄 慢闪 |
| Internet ONLINE | 黄 常亮 |
| VPN 连接中 | 蓝 慢闪 |
| VPN + PLC READY | 蓝 常亮 |
| Internet 故障 | 黄 快闪 |
| 严重故障 | 红 闪烁 |
| Failsafe | 红 常亮（内核别名默认行为） |

---

## 6. 交换机与端口布局（02_network 实测）

```
xiaomi,miwifi-mini)
    ucidef_add_switch "switch0" \
        "0:lan:2" "1:lan:1" "4:wan" "6@eth0"
```

| 逻辑 | 物理 | switch port |
| --- | --- | --- |
| LAN1 | 后面板 LAN1 | 1 |
| LAN2 | 后面板 LAN2 | 0 |
| WAN | 后面板 WAN | 4 |
| CPU | — | 6@eth0 |

- 使用 **swconfig**（`mt7620` subtarget 仍为 swconfig，`DEFAULT_PACKAGES` 含 `swconfig`），**未迁移 DSA**。
- 配置 PLC Zone 时用 swconfig VLAN，不要用 DSA 语法。
- `mediatek,portmap = "llllw"`，DTS 未额外声明 gpio 复用冲突；`state_default` 将 `ephy`、`i2c`、`rgmii1` 组设为 gpio。

---

## 7. USB 能力（对应需求 §13/§14）

- DTS 中 `&ehci`、`&ohci` 均为 `okay`，`mt7620` subtarget `FEATURES += usb ramdisk`。
- 设备默认包已含 `kmod-usb2`、`kmod-usb-ohci`（来自 `DEVICE_PACKAGES`）。
- **手机 USB Tethering** 需要：
  - `kmod-usb-net-rndis`（Android RNDIS）
  - `kmod-usb-net-cdc-ether`（部分 Android/iOS 走 CDC ECM）
  - `kmod-usb-net` + `usbutils`（诊断）
- **USB 4G/5G Modem** 需要按 Modem Profile 选择（**不要全量打包**，16MB Flash 不允许）：
  - QMI：`kmod-usb-net-qmi-wwan` + `uqmi`
  - MBIM：`kmod-usb-net-mbim` + `umbim`
  - NCM：`kmod-usb-net-huawei-cdc-ncm` + `comgt-ncm`
  - ECM：`kmod-usb-net-cdc-ether`
  - RNDIS：`kmod-usb-net-rndis`
  - 串口 PPP：`kmod-usb-serial-option` 等
- 5GHz 无线（`kmod-mt76x2`）在本网关中**只作为 STA 上联候选**，与 PLC 侧无关，可按需裁剪以省 Flash。

---

## 8. 首次刷机前必须备份的清单（需求 §65）

> 本阶段**只记录方法，不执行**。所有命令需先在原厂固件取得 root（telnet/SSH）后由人工执行。

| # | 备份对象 | 方法 | 风险 |
| --- | --- | --- | --- |
| 1 | **factory**（无线校准 + MAC） | `dd if=/dev/mtd3 of=/tmp/mtd3_factory.bin` | 丢失后无线失效/无 MAC，**不可恢复** |
| 2 | **Bdata**（板级数据） | `dd if=/dev/mtd10 of=/tmp/mtd10_bdata.bin` | 丢失后无法完整还原原厂 |
| 3 | **u-boot-env** | `dd if=/dev/mtd2 of=/tmp/mtd2_uboot_env.bin` | — |
| 4 | **Config** | `dd if=/dev/mtd2 ...`（按实际 `cat /proc/mtd` 编号核对） | 编号因批次不同会变，**必须现场核对** |
| 5 | 原厂固件 OS1/OS2 | `cat /dev/mtd4 > /tmp/mtd4_OS1.bin` | 体积大，可只留一份 |
| 6 | 当前配置 | `tar czf /tmp/backup.tar.gz /etc/config` | — |
| 7 | MAC 记录 | `cat /proc/mtd` + `ifconfig` 拍照存档 | — |

**注意**：不同批次（2015.05 之后的新板）分区编号不同，任何 `mtd` 操作前必须 `cat /proc/mtd` 现场核对，禁止照抄编号。

---

## 9. 恢复机制（需求 §63，必须保留）

| 机制 | 状态 | 说明 |
| --- | --- | --- |
| TTL 串口 | 保留 | 115200 8N1，3.3V；原厂 U-Boot 控制台**写入被禁用** |
| Failsafe | 保留 | OpenWrt failsafe + 复位键 |
| USB + Reset 恢复 | 保留 | 原厂 Ralink U-Boot 支持：FAT32/MBR U 盘放 `miwifi.bin`，按住 Reset 上电 |
| SPI 夹子直刷 | 应急 | 需要编程器（buspirate 等） |
| sysupgrade | 保留 | — |
| U-Boot 替换 | **禁止** | 需求 §63/§64 明确：未经用户确认不得修改 U-Boot |

---

## 10. 已确认 / 待确认清单

| 项目 | 状态 |
| --- | --- |
| SoC / RAM / Flash 参数 | ✅ 已确认（TOH + Techdata 一致） |
| Target / Subtarget / 包架构 | ✅ 已确认（ramips / mt7620 / mipsel_24kc） |
| DTS / 分区 / LED / Button / USB | ✅ 已确认（官方 main 分支 DTS 逐字核对） |
| 交换机布局 swconfig | ✅ 已确认（02_network） |
| 官方镜像体积 / 无 factory 镜像 | ✅ 已实测（Content-Length） |
| 无硬件加密引擎 | ✅ 已确认（DTS 无 crypto 节点） |
| TTL 引脚物理顺序（VCC/GND/TX/RX） | ⏳ `[PENDING]` — Wiki 仅提供图片，需拆机确认 |
| 真机启动 / 无线校准数据可用 | ⏳ `[PENDING]` — Phase 2 上电验证 |
| 实际 VPN 吞吐 / CPU 占用 | ⏳ `[PENDING]` — Phase 3 实测 |
