# BUILD.md — R1C Industrial Remote Gateway 构建说明

> 阶段：Phase 1
> 对应需求：§3（基础源码）、§47（配置集中）、§48（工程目录）、§53（build.sh 十步）、§54（构建产物）
> **本阶段不编译、不刷机**，本文用于确定工程形态与构建流程，编译在 Phase 2 启动。

---

## 1. 参考仓库分析（Task 2 结果）

仓库：`https://github.com/suifeng009/openwrt`（main @ `31074b2`，2026-09-15）

### 1.1 关键发现：它不是 OpenWrt 源码树

整个仓库仅 **769 KB**，不含 OpenWrt 源码。它是一个**外层构建包装仓库**：
`build.sh` 在运行时才去 clone 真正的源码树到 `./lede`。

```
suifeng009/openwrt
├── build.sh          # 一键编译（全新环境）
├── update.sh         # 增量编译（保留缓存，脏缓存检测）
├── diy-part1.sh      # feeds update 之前：改 feeds.conf.default，加第三方源
├── diy-part2.sh      # feeds install 之后：按序 source diy-part2.d/*.sh
├── diy-part2.d/      # 00-fix-cmake / 01-packages / 02-network-core
│                     # 03-uci-defaults-network / 04-uci-defaults-custom
│                     # 05-fix-ssr-plus / 10-wireguard-luci
│                     # 11-router-mode-luci / 12-change-lan-cli / 99-branding
├── .config           # 集中式配置（带大量中文注释说明"为什么"）
├── packages/         # 本地 luci-app-* 源码包，构建时复制进 package/
├── files/            # rootfs overlay
└── .github/workflows/# openwrt-builder.yml（云端构建）、update-checker.yml
```

### 1.2 可继承的机制（需求 §3 要求保留）

| 机制 | 说明 | 本项目如何复用 |
| --- | --- | --- |
| **两阶段 DIY** | `diy-part1.sh`（feeds 前）/ `diy-part2.sh`（feeds 后） | ✅ 直接继承 |
| **DIY 脚本目录化** | `diy-part2.d/NN-*.sh` 按序号执行 | ✅ 继承，序号改为 00/10/20… 便于插入 |
| **集中式 .config** | 单一配置文件 + 注释说明取舍理由 | ✅ 改为 `configs/r1c-gateway.config` |
| **本地包组织** | `packages/luci-app-xxx` 构建时拷入 | ✅ 改为 `package/r1c-gateway/` 及子包 |
| **files/ overlay** | 直接映射 rootfs | ✅ 继承（放 `/etc/r1c/`、`init.d`、脚本） |
| **build/update 分离** | 全量 vs 增量 | ✅ 继承 |
| **CI workflow** | GitHub Actions 自动构建 | ✅ 继承（release 打包用） |

### 1.3 必须剔除 / 必须新增

| 类别 | 项目 |
| --- | --- |
| ❌ 剔除 | x86_64 target、OpenClash、SSR-Plus、DDNS、UPnP、wechatpush、vlmcsd、autoreboot、snmpd、iperf3、vmdk 等家用/软路由插件 |
| ❌ 剔除 | `CONFIG_TARGET_ROOTFS_PARTSIZE=1024`、`CONFIG_VMDK_IMAGES`（x86 专用） |
| ➕ 新增 | ramips/mt7620 device `xiaomi_miwifi-mini` 配置 |
| ➕ 新增 | **固件大小检查**（需求 §44，超阈值 BUILD FAILED） |
| ➕ 新增 | SHA256 / manifest / config.buildinfo / build.log（需求 §54） |
| ➕ 新增 | `releases/` 打包与命名 |
| ➕ 新增 | Modem Profile 机制（需求 §14），按 profile 决定 USB 驱动 |

---

## 2. 基础源码树选型（✅ 最终决策：路线 A — OpenWrt 官方 24.10）

> **决策变更记录**
>
> - 2026-09-23 上午：选路线 B（`coolsnowwolf/lede`），理由是参考仓库脚本 100% 兼容、落地最快。
> - 2026-09-23 下午：GitHub Actions 首次全量编译（run `35824775628`）**失败** → 根因定位为 lede 上游缺陷 → **改选路线 A**。
>
> **路线 B 的失败证据（CI 实证 + 源码取证）**
>
> ```
> ERROR: module '.../linux-5.10.270/lib/crypto/libchacha.ko' is missing.
> *** [modules/crypto.mk:600: kmod-crypto-lib-chacha20_5.10.270-1_mipsel_24kc.ipk] Error 1
> ```
>
> | 取证项 | 实际内容 |
> | --- | --- |
> | lede `crypto.mk` 第 568 行 | `ifeq ($(KERNEL_PATCHVER),6.12)` 包裹住 **mips32r2 分支** |
> | lede ramips 可用内核 | 仅 `config-5.10` / `5.4` / `6.18` → **不存在 6.12**，MIPS 优化路径永不生效 |
> | lede `crypto.mk` 第 553 行 | `KCONFIG:=CONFIG_CRYPTO_LIB_CHACHA` |
> | Linux v5.10 `lib/crypto/Makefile` | `obj-$(CONFIG_CRYPTO_LIB_CHACHA_GENERIC) += libchacha.o` ← **符号少了 `_GENERIC`** |
>
> 结果：WireGuard 依赖的 ChaCha20 内核模块在两个环节上都不匹配，无法产出 `.ko`。
>
> **为什么路线 A 不受影响**：openwrt-24.10 的 `crypto.mk` 中 mips32r2 分支**没有版本限定**，
> `CPU_MIPS32_R2=y`（mt7620 = 24kc）时 `FILES` 被覆盖为 `arch/mips/crypto/chacha-mips.ko`，绕开了该符号。
> 且 OpenWrt 官方 24.10.5 已发布 R1C release 镜像（实测 6528 KiB）。

> 风险对冲：**锁定 commit**（`source.commit`），不追分支滚动更新。

| 对比项 | **A：openwrt/openwrt `openwrt-24.10`** | **B：coolsnowwolf/lede `master`** |
| --- | --- | --- |
| R1C 设备支持 | ✅ 官方 24.10.5 明确支持（TOH "Supported Current Rel"） | ✅ `mt7620.mk` 含 `xiaomi_miwifi-mini`，`IMAGE_SIZE=15872k` |
| 内核 | 6.6 | **5.10**（`KERNEL_TESTING_PATCHVER=6.18`） |
| 包架构 | mipsel_24kc | mipsel_24kc |
| 交换机框架 | swconfig | swconfig |
| 与参考仓库脚本兼容 | 需改造 clone 源与少量 diy 脚本 | ✅ 100% 直接兼容 |
| 官方镜像体积参考 | 6.38 MiB（实测） | 未知（`[PENDING]`） |
| 稳定性取向 | 高：release 分支、无第三方插件污染 | 中：社区滚动 master，插件生态庞大 |
| 维护风险 | 低：官方 release 有安全更新 | 中：lede master 对 mt7620 关注度逐年下降 |
| 落地成本 | 中（需适配 diy 脚本） | 低（脚本现成） |

### 2.1 路线 A 落地要点（实测自 openwrt-24.10 分支）

| 项目 | 值 |
| --- | --- |
| 源码 | `git clone --depth 1 https://github.com/openwrt/openwrt.git -b openwrt-24.10` |
| 内核 | `KERNEL_PATCHVER:=6.6` |
| 设备定义 | `xiaomi_miwifi-mini` → `Image/Device` 定义一致；`IMAGE_SIZE` 15872k |
| 交换机框架 | swconfig（`DEFAULT_PACKAGES` 含 `swconfig`） |
| 已发布参考镜像 | 24.10.5 sysupgrade = 6528 KiB（实测 Content-Length） |
| 需改造的 diy 脚本 | `diy-part1.sh` 里的 helloworld/OpenClash sed 在官方树为空操作（无害，保留作幂等保护） |

### 2.1.1 组件选型决策记录

| 组件 | 决策 | 依据 | 日期 |
| --- | --- | --- | --- |
| VPN 主方案 | WireGuard（必装）+ ZeroTier（可选备用） | `docs/VPN-COMPATIBILITY.md` 实测 | 2026-09-23 |
| Tailscale | 不入固件（EXPERIMENTAL） | installed 24.9 MiB > Flash 预算 | 2026-09-23 |
| Cloudflare / cloudflared | NOT SUPPORTED ON R1C | 25.9 MiB + WARP 不转发 ICMP | 2026-09-23 |
| **无线认证 | WPA2（`wpad-basic-mbedtls`），**不用 WPA3** | 见下方说明 | 2026-09-23（用户确认） |

**WPA3 决策说明**

需求 §12 提到"WPA3（驱动支持时）"，经用户确认**不予采用**：

- 现场场景为普通手机热点，WPA2-PSK 的安全强度已足够
- 启用 WPA3 需换用 `wpad-openssl`，引入 `libopenssl` 依赖树并增加 Flash 占用
- 收益与代价不匹配，违反 §43「不要为了功能数量安装大型软件」与 §72 优先级（稳定性优先）

生产提示：作为 STA 连接手机热点时，`wpad-basic-mbedtls` 支持 WPA2-PSK（`psk2`）。
若将来确有 WPA3 需求，需先按 §43/§44 重算 Flash 预算再改选。

### 2.0 路线 B 要点（⛔ 已废弃，保留作历史记录）

| 项目 | 值 |
| --- | --- |
| 源码 | `git clone https://github.com/coolsnowwolf/lede.git lede`，clone 后**立即 `git rev-parse HEAD` 写入 `lede.commit` 锁定** |
| 内核 | `KERNEL_PATCHVER:=5.10`（`KERNEL_TESTING_PATCHVER:=6.18`，**不使用 testing**） |
| 设备定义 | `target/linux/ramips/image/mt7620.mk` → `define Device/xiaomi_miwifi-mini`，`SOC := mt7620a`，`IMAGE_SIZE := 15872k`，`DEVICE_PACKAGES := kmod-mt76x2 kmod-usb2 kmod-usb-ohci` |
| 默认包 | `mt7620/target.mk`: `DEFAULT_PACKAGES += kmod-rt2800-soc wpad-basic-mbedtls swconfig`，`CPU_TYPE:=24kc` |
| 需剔除的 feeds | `feeds.conf.default` 中 helloworld（OpenClash/SSR 源）**保持注释**，不启用 |
| 差异注意 | lede 的 `diy-part1.sh` 原本会 `sed` 解注释 helloworld 并加入 OpenClash 源 → **本项目必须删除这两步** |

### 2.2 后续回到官方树的可选性

工程脚本（build.sh / diy / config / release）与源码树解耦：所有对源码树的改动集中在 `diy-part1.sh`、`diy-part2.d/`、`patches/`。
若日后需要迁移到官方 openwrt 24.10，只需替换 build.sh 中的 clone 源与少量 diy 脚本，**目录结构与包组织不变**。

---

## 3. 工程目录（需求 §48，已创建骨架）

```
openwrt-r1c-gateway/
├── build.sh                     # 全量构建（10 步）
├── update.sh                    # 增量构建
├── clean.sh
├── configs/
│   └── r1c-gateway.config       # 集中式编译配置
├── files/
│   ├── etc/
│   │   ├── config/              # network / firewall / wireless / system
│   │   ├── init.d/              # r1c-gateway
│   │   ├── uci-defaults/        # 首次启动注入
│   │   └── r1c/                 # site.conf
│   └── usr/bin/                 # r1c-status / r1c-diagnose / r1c-test-plc
├── package/
│   └── r1c-gateway/             # 自研包：luci-app-r1c-gateway + 服务
├── patches/                     # 源码树补丁（按 00xx-*.patch 编号）
├── scripts/
│   ├── check-size.sh            # 固件大小检查（§44）
│   ├── make-release.sh          # 打包 + sha256 + manifest
│   └── backup-mtd.sh            # 刷机前分区备份（仅提供，不自动执行）
├── docs/
│   ├── HARDWARE.md              # ✅ 已完成
│   ├── BUILD.md                 # ✅ 本文
│   ├── VPN-COMPATIBILITY.md     # ✅ 已完成
│   ├── NETWORK.md               # ⏳ Phase 2
│   ├── VPN.md                   # ⏳ Phase 3
│   ├── PLC.md                   # ⏳ Phase 10
│   ├── MODEM.md                 # ⏳ Phase 5/6
│   └── TEST.md                  # ⏳ Phase 10
└── releases/
```

参考仓库副本保存在 `../reference-suifeng009-openwrt/`（只读参考，不参与构建）。

### 3.1 骨架落地状态（Phase 1 已创建，未编译）

| 文件 | 状态 |
| --- | --- |
| `build.sh` / `update.sh` / `clean.sh` | ✅ 已建（build.sh 十步 + commit 锁定） |
| `diy-part1.sh` / `diy-part2.sh` / `diy-part2.d/10-r1c-gateway.sh` | ✅ 已建（已剔除 helloworld/OpenClash 源） |
| `configs/r1c-gateway.config` | ✅ 已建（ramips/mt7620 + WireGuard + ZeroTier，明确排除 Tailscale/cloudflared） |
| `scripts/check-size.sh` | ✅ 已建（12MiB WARN / 15MiB FAIL / 15872 KiB 硬上限） |
| `scripts/make-release.sh` | ✅ 已建（sha256 / manifest / config.buildinfo / build.log） |
| `scripts/backup-mtd.sh` | ✅ 已建（只读备份，**不会被 build.sh 调用**） |
| `scripts/deps-ubuntu.sh` | ✅ 已建 |
| `package/r1c-gateway/Makefile` | 🟡 骨架（业务逻辑 Phase 2–9 填充） |
| `files/etc/init.d/r1c-gateway` | 🟡 骨架（procd 服务，主循环 TODO） |
| `files/usr/bin/r1c-status` | 🟡 可用（读 site.conf + 基础状态） |
| `files/usr/bin/r1c-diagnose` | 🟡 可用（9 项只读诊断） |
| `files/usr/bin/r1c-test-plc` | 🟡 可用（Ping/TCP/Route/ARP，严格只读） |
| `files/etc/r1c/site.conf` | ✅ 已建（Site ID / PLC / VPN / WAN / 维护窗口） |
| `patches/` / `releases/` | ⏳ 空目录待用 |

---

## 4. 构建环境

| 项目 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 LTS / 24.04 LTS，或 WSL2 |
| 用户 | **禁止 root**（参考仓库 build.sh 已内置检查） |
| 路径 | **禁止含空格**（内置检查） |
| 磁盘 | ≥ 30 GB（内置检查） |
| 网络 | 需稳定访问 GitHub 与源码镜像 |

依赖（沿用参考仓库的 Lean 官方依赖清单，Ubuntu 22.04 验证过）：

```bash
sudo apt-get install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison \
build-essential bzip2 ccache cmake cpio curl device-tree-compiler fastjar flex gawk gettext \
gcc-multilib g++-multilib git gperf haveged help2man intltool libc6-dev-i386 libelf-dev \
libfuse-dev libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev libncurses5-dev \
libncursesw5-dev libpython3-dev libreadline-dev libssl-dev libtool lrzsz mkisofs msmtp \
ninja-build p7zip p7zip-full patch pkgconf python3 python3-pyelftools python3-setuptools \
qemu-utils rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip vim \
wget xmlto xxd zlib1g-dev python3-pip
```

---

## 5. build.sh 十步流程（需求 §53）

| # | 步骤 | 说明 |
| --- | --- | --- |
| 1 | 检查 Ubuntu 依赖 | 复用参考仓库的 apt 清单 |
| 2 | 检查 Git 与源码树 | 不存在则 clone（源由**路线 A/B** 决定）；存在则 update |
| 3 | 更新 Feeds | `./scripts/feeds update -a && ./scripts/feeds install -a`（中间插入 `diy-part1.sh`） |
| 4 | 加载 R1C 配置 | `cp configs/r1c-gateway.config .config && make defconfig` |
| 5 | 应用 Patch | `patches/*.patch` 按序 `git apply` |
| 6 | 编译 | `make download -j8` 重试 3 次 → `make -j$(nproc+1)`，失败自动 `make -j1 V=s` 复现 |
| 7 | **固件大小检查** | `scripts/check-size.sh`，超阈值 **exit 1（BUILD FAILED）** |
| 8 | SHA256 | `sha256sums` |
| 9 | Manifest | 版本/commit/配置/包清单 |
| 10 | Release 打包 | `scripts/make-release.sh` |

### 5.1 固件大小检查规则（需求 §44）

```bash
# scripts/check-size.sh（逻辑）
IMAGE_SIZE_LIMIT_K=15872     # mt7620.mk IMAGE_SIZE for miwifi-mini
WARN_K=$((12*1024))          # 12288 KiB
FAIL_K=$((15*1024))          # 15360 KiB

size=$(stat -c%s "$BIN")
if   [ "$size" -gt "$IMAGE_SIZE_LIMIT_K*1024" ]; then echo "BUILD FAILED: > IMAGE_SIZE"; exit 1
elif [ "$size" -gt "$FAIL_K*1024" ];            then echo "BUILD FAILED: > 15 MiB";      exit 1
elif [ "$size" -gt "$WARN_K*1024" ];            then echo "WARN: overlay 空间不足"; exit 0
else                                                 echo "OK";                      exit 0
fi
```

---

## 6. configs/r1c-gateway.config 骨架（待路线确认后落地）

```ini
# ---------- Target ----------
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt7620=y
CONFIG_TARGET_ramips_mt7620_DEVICE_xiaomi_miwifi-mini=y
# 禁止：x86_64 / vmdk / ROOTFS_PARTSIZE=1024

# ---------- 基础（需求 §45） ----------
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_dropbear=y
CONFIG_PACKAGE_dnsmasq=y            # 非 dnsmasq-full（省空间）
CONFIG_PACKAGE_firewall=y           # 或 firewall4，按路线内核决定
CONFIG_PACKAGE_netifd=y
CONFIG_PACKAGE_procd=y
CONFIG_PACKAGE_uci=y
CONFIG_PACKAGE_kmod-usb2=y
CONFIG_PACKAGE_kmod-usb-ohci=y

# ---------- VPN：WireGuard（PRIMARY） ----------
CONFIG_PACKAGE_kmod-wireguard=y
CONFIG_PACKAGE_wireguard-tools=y
CONFIG_PACKAGE_luci-proto-wireguard=y
CONFIG_PACKAGE_kmod-tun=y

# ---------- VPN：ZeroTier（OPTIONAL，默认安装但服务默认关闭） ----------
CONFIG_PACKAGE_zerotier=y
# CONFIG_PACKAGE_luci-app-zerotier=y   # 视 Flash 预算决定

# ---------- 明确不装（需求 §45/§46） ----------
# Tailscale：安装体积 24.9 MiB，超出预算 → 不装
# CONFIG_PACKAGE_tailscale is not set
# cloudflared：25.9 MiB + 不转发 ICMP → NOT SUPPORTED ON R1C
# CONFIG_PACKAGE_cloudflared is not set
# Docker / Python / Node.js / Samba / Transmission / AdGuardHome → 全部不装

# ---------- 多 WAN（需求 §15，Flash 允许时装） ----------
CONFIG_PACKAGE_mwan3=y
CONFIG_PACKAGE_luci-app-mwan3=y

# ---------- 诊断工具（轻量） ----------
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_tcpdump-mini=y      # 非完整 tcpdump
CONFIG_PACKAGE_ethtool=y
CONFIG_PACKAGE_usbutils=y

# ---------- 时间同步（需求 §19） ----------
CONFIG_PACKAGE_ntpd=y              # 或 chrony 轻量版，按体积选

# ---------- 版本 ----------
CONFIG_VERSION_NUMBER=""           # 由 build.sh 注入
```

---

## 7. 构建产物（需求 §54）

```
releases/
├── r1c-gateway-YYYY.MM.DD-HHMM-sysupgrade.bin
├── r1c-gateway-YYYY.MM.DD-HHMM-initramfs-kernel.bin    # 首次装机/救砖用
├── sha256sums
├── manifest                 # 源码 commit / 内核版本 / 包清单 / 镜像大小
├── config.buildinfo         # 实际生效的 .config
└── build.log
```

> 官方 24.10.5 **不提供 factory 镜像**（实测 404）；R1C 首次装机使用 `initramfs-kernel.bin` 引导后再 sysupgrade，或按 TOH 流程从原厂写入 `OS1`。

---

## 8. 安全红线（需求 §64 / §68）

本工程脚本与执行过程**严禁**自动执行以下操作：

- `mtd erase` / `mtd write` / `sysupgrade`（需用户显式确认）
- U-Boot 修改 / 替换
- 分区表变更
- flash 擦写
- 擅自删除无线驱动或恢复机制

`scripts/backup-mtd.sh` 只提供备份能力，**不会**被 build.sh 自动调用，且不允许在构建主机上对设备发起任何写操作。

---

## 9. 云端构建：GitHub Actions（已落地 `.github/workflows/build-r1c.yml`）

### 9.1 可行性：✅ 可以，但有硬约束

| 项目 | GitHub 官方规格（2026 实测自官方文档） |
| --- | --- |
| 公开仓库 runner | **4 vCPU / 16 GB RAM / 14 GB SSD**，免费且分钟数无限 |
| 私有仓库 runner | **2 vCPU / 8 GB RAM / 14 GB SSD**，消耗账户配额 |
| 单 job 上限 | 6 小时 |
| Artifact 保留 | 默认 90 天（工业固件建议下载后自行归档） |

**唯一真正的瓶颈是 14 GB SSD**：OpenWrt 完整编译（源码 + feeds + `dl` + `build_dir`）通常需要 20–40 GB。
本项目可绕过这个限制，原因是**针对性做了减法**：

- 单 target（`ramips/mt7620`）、单 device（`xiaomi_miwifi-mini`），不编译其他 target
- 已剔除 OpenClash / SSR-Plus / Docker / Python / Node 等大体积依赖树
- workflow 中 `jlumbroso/free-disk-space` 清理预装的 Android/dotnet/Haskell/Docker 镜像
- 使用 `--depth 1` 浅克隆

若仍遇到 `No space left on device`，退路见 9.3。

### 9.2 三种构建方式对比

| 方式 | 优点 | 缺点 | 适用 |
| --- | --- | --- | --- |
| **A. GitHub Actions** | 零本地环境、可复现、自动生成 Release 归档 | 14 GB 磁盘上限；首次全量约 1–3 小时；私有仓更慢 | 推荐起步 |
| **B. 自建 runner（self-hosted）** | 无磁盘/时长限制、可用本地大磁盘与多核、固件不出内网 | 需一台常驻 Linux 机器（WSL2 也可注册） | 长期主力 |
| **C. 本地直接编译** | 最可控、调试最快 | 需要本机 ≥30 GB 的 Linux 环境 | 调试期 |

**建议组合**：调试期用 B/C，稳定后推到 A 做归档发布。

### 9.3 触发方式

```bash
git add . && git commit -m "r1c: xxx" && git push
# 或手动触发：GitHub → Actions → R1C Gateway Builder → Run workflow
```

触发条件：仅当 `configs/`、`files/`、`package/`、`patches/`、`diy-*` 或 workflow 本身变更时自动构建（避免无关提交浪费 CI）。

### 9.4 针对 R1C 的改造点（相对参考仓库 workflow）

| 参考仓库（P3TERX 模板） | 本项目 |
| --- | --- |
| x86_64 + VMDK/ESXi 转换步骤 | ❌ 删除；改为 `ramips/mt7620` 产物 |
| 仓库根 `.config` | `configs/r1c-gateway.config` |
| 追分支最新代码 | ✅ 锁定 `source.commit`（可复现；可用 `force_unlock` 手动解除） |
| 无体积检查 | ✅ `scripts/check-size.sh`，超 15 MiB 直接失败 |
| 无 release 打包 | ✅ `scripts/make-release.sh`（sha256 / manifest / config.buildinfo） |
| 删除旧 Release（保留 10） | ❌ 不删 —— 工业固件需可追溯归档 |
| 无 ccache | ✅ 缓存 `/workdir/.ccache` 加速增量 |
| 每日定时构建 | ❌ 去掉 —— 工业固件不做无人值守滚动构建 |

### 9.5 安全注意事项

- **不要把 VPN 私钥、站点凭据、PLC 地址清单提交到公开仓库**。`files/etc/r1c/site.conf` 目前只含占位值，真实现场配置应在部署后写入设备，或走私有仓库。
- 公开仓库免费无限分钟，但源码与配置对外可见；若固件配置敏感，请用**私有仓库 + 配额**，或改用自建 runner。
- 云端产物仅供下载，**刷机动作始终在本地由人工确认执行**（需求 §64）。
