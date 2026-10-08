# R1C Industrial Remote Gateway — Firmware

> Turn a Xiaomi MiWiFi Mini (R1C) running OpenWrt 24.10 into an **industrial remote-maintenance gateway for PLCs**.
> All the site needs is any working Internet link (phone hotspot / 4G / Ethernet). Once the WireGuard tunnel is up,
> an engineer connects from the office directly to the PLC — as if sitting next to the cabinet.

[简体中文](README.md) | English

| Item | Value |
| --- | --- |
| Device | Xiaomi MiWiFi Mini (R1C / R1CM) |
| Source tree | `openwrt/openwrt`, branch `openwrt-24.10` (kernel 6.6.x) |
| Target | `ramips/mt7620` → `xiaomi_miwifi-mini`, arch `mipsel_24kc` |
| Primary tunnel | WireGuard (ZeroTier as fallback) |
| Build | One-click via GitHub Actions, or locally with `build.sh` |
| Flash budget | `firmware` partition 15872 KiB; produced sysupgrade ≈ 10.4 MiB |

---

## 1. The problem it solves

The PLC sits on a private shop-floor network (e.g. `192.168.10.30`, Siemens TCP/102 or Modbus TCP/502)
and the engineer is somewhere else. Traditionally you either travel to the site, or ask the customer to
open port forwards or set up a VPN — expensive, slow, and usually not permitted.

This project drops a $10 router next to the PLC. It gets online by itself over a phone hotspot or 4G
and **dials out** to a Hub over WireGuard. Once the engineer joins the Hub, they can type the PLC's
private IP into TIA Portal / STEP 7 and it just works.

```
      Office / Home                    Internet                        Shop floor
┌──────────────────┐           ┌──────────────┐             ┌──────────────────┐
│ Engineer PC      │ WireGuard │              │  hotspot /  │      R1C         │
│ TIA / STEP 7 ────┼──────────▶│  Hub  (VPN)  │◀── 4G ──────┼── WAN (STA)      │
│ ping / browser   │  tunnel   │  UDP 51821   │  ETH        │        │         │
└──────────────────┘           └──────────────┘             │        ▼         │
                                                            │  PLC 192.168.10.x│
                                                            │  HMI / switch    │
                                                            └──────────────────┘
```

Key point: **the R1C is the side that initiates the outbound connection.** The shop-floor network needs
no inbound ports, no port forwarding, and no changes to the customer's existing gateway
(see the `PLC_ROLE=host` mode below).

---

## 2. Features

| Area | What it does |
| --- | --- |
| **No network baked into the image** | PLC subnet and VPN addressing live in `/etc/r1c/site.conf`. Edit it, run `r1c-apply`, done — **no recompile, no reboot** |
| **Two attachment roles** | `PLC_ROLE=gateway` (R1C is the PLC subnet's gateway) or `host` (R1C is just another host; the existing network is untouched) |
| **Tunnel self-healing** | `r1c-wg-watchdog` re-resolves the Hub hostname every 30s. WireGuard's kernel only caches the resolved IP, so after a home broadband re-dial DDNS *cannot* save the tunnel — this daemon can |
| **Flexible uplink** | Ethernet / USB 4G / USB tethering / WiFi STA, chosen automatically per `WAN_PRIORITY` |
| **No lockout when the uplink breaks** | A 5 GHz emergency AP is always on, serving `/cgi-bin/r1c`, so you can fix the WiFi with a phone even when the tunnel is dead (see §6) |
| **Local rescue page** | Plain busybox-ash CGI with 5 tabs and zero extra dependencies — still reachable when the tunnel is down |
| **LuCI menu entry** | The same page is mounted in the web UI under "R1C Gateway" out of the box |
| **Survives upgrades** | `keep.d/r1c-gateway` preserves `/etc/r1c/` across sysupgrade, so site config and WireGuard keys are never wiped |
| **Chinese UI** | Simplified-Chinese LuCI language packs injected at build time |
| **Read-only health checks** | `r1c-status` / `r1c-diagnose` only do ICMP and TCP reachability — **no write commands are ever sent to the PLC** |

### Explicitly unsupported / not recommended

| Option | Verdict |
| --- | --- |
| Tailscale | 24.9 MiB installed — **exceeds the flash budget**; excluded from the image |
| cloudflared | 25.9 MiB, and WARP routing does not forward ICMP (ping never works); dropped |
| L2 bridging between sites | Forbidden. Same-subnet multi-site setups must use L3 routing plus address mapping |

---

## 3. Quick start

### 3.1 Use a prebuilt image (recommended)

```bash
# Download from Releases (public repo — anonymous download works)
gh release download <version> -R <owner>/<repo> -p "*.bin" -p "sha256sums"

# Verify
sha256sum -c sha256sums
```

What each artifact is for:

| File | Purpose |
| --- | --- |
| `r1c-gateway-<ver>-sysupgrade.bin` | **Flash this one** (writes to Flash permanently) |
| `r1c-gateway-<ver>-initramfs-kernel.bin` | RAM-only system used for the first flash from breed, or for recovery — **never written to Flash** |
| `sha256sums` | Image checksums |
| `manifest` | Build metadata: source commit, kernel version, image sizes, VPN selection rationale |
| `config.buildinfo` | The exact `.config` used — use it to reproduce a build |
| `build.log` | Excerpted compile log (all errors/warnings + last 3000 lines) |

### 3.2 Build it yourself

See [docs/BUILD.md](docs/BUILD.md). Both paths produce the same result:

```bash
# A. Local build (needs >= 30 GB free disk, non-root user)
./build.sh     # full: fetch source -> feeds -> config -> compile -> size check -> release package
./update.sh    # incremental (keeps caches)

# B. Cloud build (recommended)
git push origin main   # auto-triggers when configs/ files/ package/ patches/ diy-*.sh change
# or start it manually from the Actions tab ("Run workflow"), optionally ignoring the source lock
```

A cloud build takes roughly **50–95 minutes** and publishes a Release automatically.
Version tags use the format `YYYY.MM.DD-HHMM`.

> The upstream source commit is pinned in `source.commit` for **reproducibility**.
> To follow upstream, change that file deliberately — don't let it drift silently.

---

## 4. Flashing

Full runbook: [docs/FLASH-RUNBOOK.md](docs/FLASH-RUNBOOK.md);
rationale and troubleshooting: [docs/FIRST-BOOT.md](docs/FIRST-BOOT.md).
Below are only the things people get wrong most often.

### ⛔ Three red lines

1. **Back up the `factory` and `Bdata` partitions first, and store them on your PC.** `factory` holds the
   wireless EEPROM and MAC address. Lose it and Wi-Fi is **permanently dead — it cannot be copied from another unit**.
2. **Never** modify the bootloader, partition table, or partition layout, and never write to
   `factory`, `Bdata` or `u-boot-env`.
3. In breed, set "firmware startup settings → type" to **Xiaomi MINI**. Getting this wrong shows up as
   "it flashes fine but never boots".

### Flow overview

```
breed (192.168.1.1) ── flash initramfs (RAM-only) ──▶ OpenWrt running ── sysupgrade ──▶ real firmware
```

```sh
# Once you are inside the RAM system
sysupgrade -T /tmp/xxx-sysupgrade.bin   # pre-flight check first
sysupgrade     /tmp/xxx-sysupgrade.bin  # then flash (never force with -F if it refuses)
```

> ⚠️ **First boot after sysupgrade takes about 7 minutes** (measured: 6.5–7 min). During that window being
> unpingable and unreachable over SSH is *normal* — don't declare it bricked. Instead check whether your
> **wired NIC still reports a 100 Mbps link**: if it does, the flash is still being written.

---

## 5. Site configuration: `/etc/r1c/site.conf`

**This is the only file you need to edit on site.** Everything in the image is a placeholder — no real
subnet is compiled in.

```sh
vi /etc/r1c/site.conf
r1c-apply --check     # validate first
r1c-apply --dry-run   # see what it intends to change (strongly recommended)
r1c-apply             # apply for real: reloads network/firewall, no reboot
```

### Required fields

| Parameter | Meaning | Common pitfall |
| --- | --- | --- |
| `SITE_ID` | Site identifier, globally unique | Duplicate IDs make sites overwrite each other's routes |
| `PLC_ROLE` | `gateway` / `host` | `host` requires the existing gateway to have a return route to the VPN subnet |
| `PLC_NETWORK` | PLC subnet, e.g. `192.168.10.0/24` | — |
| `PLC_GATEWAY` / `PLC_LOCAL_IP` | Pick the one matching the role | **Never** set a default gateway on LAN — it competes with the WAN route and kills the tunnel itself |
| `VPN_ADDR` | This unit's tunnel address, **unique per site** | — |
| `WG_ENDPOINT` | Hub's public endpoint, `host:port` | — |
| `WG_PEER_PUBLIC_KEY` | Hub's public key | — |
| `WG_PEER_ALLOWED_IPS` | Destination prefixes routed into the tunnel | **Never `0.0.0.0/0`** — that hijacks the default route and starves the uplink |
| `WG_PRIVATE_KEY_FILE` | Path to this unit's private key | Keep keys **out of `site.conf`** (it's in the repo); store separately with mode 600 |
| `WG_PRESHARED_KEY_FILE` | Path to the PSK | A missing PSK only shows up as handshake timeout — painful to debug |
| `AUTO_APPLY` | Apply on boot | **Must stay 0 from factory**, otherwise the placeholder config rewrites LAN and makes a fresh flash look failed |

### Security-relevant parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `PLC_WAN_ACCESS` | `deny` | Blocks the PLC side from reaching the Internet |
| `VPN_HTTP_ACCESS` | `allow` | Whether the admin UI is reachable over the VPN. Ships as `allow`, so the UI opens as soon as the tunnel is up; set `deny` to lock it down. Opening it is **never unconditional**: with no root password set, `r1c-apply` still refuses and warns |
| `REMOTE_MAINTENANCE` | `disabled` | Remote maintenance toggle and timeout |

### Multiple uplinks and failover (4G is a backup by default)

| Parameter | Default | Notes |
| --- | --- | --- |
| `WAN_PRIORITY` | `ethernet wifi usb4g usbtether` | Uplink order. **4G ships as a backup** — it takes over only when both Ethernet and the hotspot are down |
| `WAN_FAILOVER` | `metric` | `metric` lets the kernel pick by metric (default, no dependencies, verified on real hardware) / `mwan3` actively probes / `off` |
| `MWAN_TRACK_IPS` | three public DNS servers | Probe targets. **Do not put the Hub address here** — if a probe target dies, the uplink gets switched away for nothing |
| `WAN_4G_DEVICE` / `WAN_TETHER_DEVICE` | `auto` | Auto-detect by driver name; can be pinned to `eth1` / `usb0` |

- **Ethernet WAN works out of the box**: plug in a working cable and it goes online, no configuration. 4G and USB tethering are backups.
- **A USB 4G dongle boots in mass-storage mode** and only becomes a NIC after `usb-modeswitch` flips it.
  Measured on a Huawei E3131: `12d1:1f01` (storage) → `12d1:14db`, then `cdc_ether` registers `eth1`.
  That is HiLink NIC mode — **no PPP/QMI dialling needed**.
- **The dongle does not have to be plugged in at apply time**: `r1c-apply` still creates the interface and
  adds it to the policy (standing by). Plug it in later and hotplug takes over — **no need to re-run apply**.
- ⚠️ This is **failover, not load balancing**: WireGuard is a single UDP flow. Balancing it across two uplinks
  makes the source IP flip back and forth, so the Hub keeps seeing a new endpoint — the tunnel rebuilds every
  few minutes and the PLC goes intermittent.
**Measured 2026-10-08 with a Huawei E3131 as the backup uplink**: after dropping the WiFi primary,
the default route moved to 4G immediately, the tunnel recovered in **0 seconds** and the PLC stayed at
1.7 ms with zero loss; when the primary came back it switched back on its own. No conntrack flush is
needed — a new uplink means a new source IP, which means a new 5-tuple, so WireGuard roaming just works.

> `mwan3` is **not the default**: on this image (24.10 + mwan3 2.11.16 + fw4) probing does not hold —
> every interface reads `online` for 1–2 seconds, then `disconnecting`, then `offline` about 40 s later,
> leaving the policy `unreachable`. Ruled out: `flush_conntrack`, `family`, ping compatibility,
> setuid/LD_PRELOAD, probe-target reachability. Root cause not identified.
> If you do need "interface up but no Internet" detection, enable it and validate with `mwan3 status` first.

> Full parameter list with per-line rationale: [`files/etc/r1c/site.conf`](files/etc/r1c/site.conf).

---

## 6. When the tunnel dies (emergency access)

The classic site failure looks like this: **the phone hotspot is replaced or its password changes → STA can't
associate → tunnel is down → the Hub can't reach the gateway → you can't fix the WiFi → deadlock.**

Two things in this design break that loop:

1. **5 GHz emergency AP** — the 5 GHz radio (radio0) permanently hosts an AP whose SSID and password are
   factory defaults (see `AP_SSID` / `AP_KEY` in
   [`files/etc/uci-defaults/92-r1c-emergency-ap.sh`](files/etc/uci-defaults/92-r1c-emergency-ap.sh)).
   Connect a phone or laptop straight to it and you get an address in the LAN subnet
   (the DHCP pool is deliberately narrowed to `.240–.249` to avoid PLC addresses).
2. **Local rescue page** — open `http://<lan-address>/cgi-bin/r1c`, five tabs:

   | Tab | What it does |
   | --- | --- |
   | **Status** | WAN / VPN / PLC device health (ICMP + TCP/102) |
   | **WiFi** | Change the STA SSID and password (breaks the loop above) |
   | **Site** | Edit `site.conf` and run apply |
   | **Log** | Service log |
   | **Diag** | Run `r1c-diagnose` and produce a report |

   The same page is also mounted in the LuCI menu as "**R1C Gateway**" (`admin/r1c`).

> It sits on 5 GHz rather than 2.4 GHz on purpose: 2.4 GHz (radio1) is reserved for the STA uplink to the
> phone hotspot, the two radios are independent, and 2.4 GHz is where the interference lives.
> If the site requires zero wireless exposure after servicing:
> `uci set wireless.r1c_ap.disabled=1; uci commit wireless; wifi reload`

---

## 7. Command-line tools

| Command | Purpose |
| --- | --- |
| `r1c-status` | One screen: Site ID / WAN / VPN / PLC and overall health; JSON output available for scraping |
| `r1c-apply` | Applies `site.conf` to UCI (`--check` validates, `--dry-run` only prints) |
| `r1c-diagnose` | Writes a report to `/tmp/r1c-diagnose-*.txt`; read-only, no config changes, no reboots |
| `r1c-test-plc` | Connectivity test against the `PLC_DEVICES` list — **no write operations, ever** |
| `r1c-wg-watchdog` | Single-shot endpoint re-resolution; **don't run it by hand** — the service loop calls it every `CHECK_INTERVAL` (default 30s) |

The service itself is a `procd`-supervised loop that restarts itself on crash:

```sh
/etc/init.d/r1c-gateway {start|stop|restart|status}    # enabled by default
logread -e r1c                                         # read its logs
```

---

## 8. Repository layout

```
openwrt-r1c-gateway/
├── configs/r1c-gateway.config      # kconfig config (NB: no trailing comments on `=y` lines — silently ignored)
├── files/                          # rootfs overlay — new files MUST be registered in the Makefile install section
│   ├── etc/r1c/site.conf           #   the single source of truth for site config (placeholders)
│   ├── etc/init.d/r1c-gateway      #   procd main-loop service
│   ├── etc/uci-defaults/           #   90 STA template / 91 LuCI zh-CN / 92 emergency AP / 93 factory root pw
│   ├── lib/upgrade/keep.d/         #   preserve /etc/r1c/ across upgrades
│   ├── usr/bin/                    #   r1c-status / apply / diagnose / test-plc / wg-watchdog
│   ├── usr/share/luci/menu.d/      #   LuCI menu entry
│   └── www/                        #   cgi-bin/r1c (rescue page) + luci-static JS view
├── package/r1c-gateway/            # home-grown package Makefile (files/ synced in by the diy script)
├── diy-part1.sh / diy-part2.sh     # build hooks (before/after feeds)
├── diy-part2.d/10-r1c-gateway.sh   # injects the package, restores exec bits, force-adds language packs
├── scripts/                        # make-release / check-size / backup-mtd / flash-over-ssh, etc.
├── patches/                        # source patches (currently empty)
├── source.commit                   # pinned upstream commit
└── .github/workflows/build-r1c.yml # cloud build and automatic release
```

The companion **Hub server** (multi-site dashboard, bulk config push, snapshot rollback, health polling)
is a separate component and is **not part of this repository**.

---

## 9. Documentation

| Doc | Contents |
| --- | --- |
| [docs/HARDWARE.md](docs/HARDWARE.md) | Hardware confirmation: partition table, GPIO/LED map, switch layout, measured flash budget |
| [docs/BUILD.md](docs/BUILD.md) | Build system: why the lede tree was abandoned, why the commit is pinned, repo shape |
| [docs/NETWORK.md](docs/NETWORK.md) | Network architecture: why subnets stay out of the image, config layering, role differences |
| [docs/VPN-COMPATIBILITY.md](docs/VPN-COMPATIBILITY.md) | WireGuard / ZeroTier / Tailscale / cloudflared selection data for mt7620 (with measured sizes) |
| [docs/FLASH-RUNBOOK.md](docs/FLASH-RUNBOOK.md) | Step-by-step flashing manual (pre-flight checklist + three-phase flow) |
| [docs/FIRST-BOOT.md](docs/FIRST-BOOT.md) | What happens on first boot, and how to debug "it looks dead" |

---

## 10. Known limitations

- **First boot after sysupgrade takes ~7 minutes.** Leave it alone during that window.
- **No hardware crypto engine** (MT7620A has no crypto node), so WireGuard is pure software on a single
  580 MHz core with limited throughput — don't stack a second encrypted tunnel on top.
- **HTTPS (443) is unavailable by default**: neither `px5g` nor `openssl` is compiled in, so uhttpd cannot
  self-sign a certificate. Use HTTP (80) for the UI; traffic plaintext only exists inside the tunnel and
  the local LAN.
- `HOSTNAME` is not applied automatically yet, and `r1c-apply` does not manage WiFi reconnect policy.

### FAQ

**Q: I can ping the R1C but can't open its web UI.**
A: The `vpn` firewall zone defaults to `input REJECT`, allowing only SSH (22) and ICMP; ports 80/443 need
`VPN_HTTP_ACCESS=allow` (which is the factory value). Check two things: ① the value in `site.conf` — and run
`r1c-apply` after changing it; ② whether root has a password — with none set, `r1c-apply` refuses to open it.
Note this governs access **to the R1C itself**; reaching **other devices** on the subnet (PLC, HMI) goes
through the forward chain, which has **no port filtering** at all.

**Q: What is the factory root password?**
A: The factory root password is **`password`** — deliberately weak, and public: this repo is open, the
sha256crypt hash sits in `uci-defaults/93-r1c-root-password.sh` and the plaintext is spelled out in its
comments. **Change it with `passwd` as the very first step on site.** Once changed, the script never touches
it again (not even across upgrades).
⚠️ This repository is public: all examples use placeholder subnets and `site.conf` ships placeholder values
only; real site configuration lives on the device.

**Q: Handshake looks fine but the PLC is unreachable.**
A: Usually a multi-site **subnet collision** — the same CIDR assigned to two peers makes WireGuard silently
drop the last one. One CIDR must belong to exactly one peer.

---

## 11. License

The firmware is based on [OpenWrt](https://github.com/openwrt/openwrt) (GPL-2.0-only).
The scripts and tools developed in this repository (`files/`, `package/r1c-gateway/`, `scripts/`)
are GPL-2.0-only as well.
