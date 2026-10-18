# wireless-wifi-mt7603u — fork with a modern-kernel / OpenWrt port

Driver for the **MediaTek MT7603U** 2×2 802.11n USB chip as found in the
**360 随身WiFi 3** dongle (USB ID `0e8d:760c`).

Upstream: [aniudashi/wireless-wifi-mt7603u](https://github.com/aniudashi/wireless-wifi-mt7603u)
— a 2014-era MediaTek/Ralink `DPOA` vendor drop that only ever built against
Linux 3.10.

This fork keeps that tree and its layout, and adds:

* **The port itself** — 42 files, ~1.2k insertions, enough to build cleanly on
  Linux 6.1 … 6.18 and to *run* on both Debian (out-of-tree module) and OpenWrt.
* **OpenWrt 24.10 packages** (`openwrt/`) — `kmod-mt7603u-ap`,
  `kmod-mt7603u-sta`, `mt7603u-files`, with the firmware blobs and the
  vendor's `RT2870AP`/`RT2870STA` runtime config.
* **Prebuilt ipks** (`dist/`) for OpenWrt 24.10.2 x86_64 — verified there.
* **A QEMU/KVM harness** (`tools/`) that boots a real OpenWrt image and passes
  the USB stick through, so the driver can be tested without touching a router.
* **The reports** — `openwrt/REPORT.md` (this port, in Chinese) and the Debian
  bring-up it builds on, including the measurements.

`git diff upstream:master` is the port. Nothing else in `DPOA/` was touched.

## Status

| | Status |
|---|---|
| Builds against Linux 6.6.93 (OpenWrt 24.10) | ✅ 0 errors, 0 unresolved symbols |
| Builds against Linux 6.12 / 6.18 (Debian / Armbian) | ✅ (see the report) |
| **AP mode** (hostapd) | ✅ assoc + WPA2 + DHCP + ping, real client |
| **STA mode** (wpa_supplicant) | ✅ assoc + DHCP + `iperf3` TX 30.5 / RX 52.8 Mbit/s |
| OpenWrt package install / reboot autoload | ✅ verified in a VM |
| OpenWrt UCI/LuCI integration | ❌ not done — this is a vendor cfg80211 driver, not mac80211, so netifd does not manage it |

## Why the port is not just "fix the compile errors"

OpenWrt is the awkward case: **the kernel is older than the wireless API**.
A 6.6.93 kernel ships *backports* 6.12.6 cfg80211, so `#include <net/cfg80211.h>`
describes the 6.12 ABI while `LINUX_VERSION_CODE` says 6.6. Gating cfg80211 code
on the kernel version therefore picks the wrong branch, and because
`CPTCFG_*` switches change `struct wiphy` / `struct wireless_dev` /
`struct cfg80211_ops` layouts, "wrong branch" means silent memory corruption
rather than a failed build.

The port introduces `RTMP_CFG80211_API_VER` (the cfg80211 API generation,
independent of the kernel version) and gates only the wireless bits on it.
The full list of pitfalls — header search order (`NOSTDINC_FLAGS` vs
`ccflags-y`), the `mac80211-backport` compat layer that must *not* be pulled in,
the three symbols that only exist when cfg80211 is built with WEXT, and the
5-field `Module.symvers` format that kernel 6.6's `modpost` insists on — is in
[`openwrt/REPORT.md`](openwrt/REPORT.md).

## Build & install

```sh
# full walkthrough: SDK setup, the mac80211 headers, packaging
less openwrt/README.md
```

Quick version, on an OpenWrt 24.10.2 x86_64 box:

```sh
opkg update
opkg install kmod-cfg80211 kmod-mac80211
opkg install dist/mt7603u-files_1_all.ipk dist/kmod-mt7603u-ap_6.6.93-r1_x86_64.ipk

ip link set wlan0 up
iw dev                  # `type AP`, MAC filled in from EFUSE
```

AP mode needs a `hostapd` config (`openwrt/package/kernel/mt7603u/files/hostapd.conf.example`),
STA mode needs `wpa_supplicant` (`wpa_supplicant.conf.example`).
Keep them installed one at a time: both modules claim the same USB ID, register
the same driver name `mt_drv`, *and* export the same symbol, so they cannot be
loaded together.

## Testing without hardware in the loop

`tools/` is a small harness: prepare an OpenWrt ext4 image with SSH access,
boot it under QEMU/KVM with `-device qemu-xhci` + `usb-host` for the real stick
(hot-pluggable through the monitor socket), then drive it over SSH.

```sh
cp .env.example .env      # local VM password / test PSK, nothing real
set -a; . ./.env; set +a

tools/owrt-vm-prep.sh     # inject ssh key/password into the image
tools/owrt-vm-start.sh    # boot it
tools/owrt-vm-ssh.sh 'uname -a'
tools/owrt-vm-ap-up.sh    # bring the stick up as an AP
```

Two things that cost real time, documented in the scripts:

* The QEMU guest must be reached through its **wan**-side hostfwd. With two
  user-netdevs both on `10.0.2.0/24`, a lan-side forward answers its SYN with a
  packet the guest routes out of the *wan* interface, and the connection dies
  during banner exchange.
* Any `ssh`/`scp` invoked from inside a script that itself arrived over
  `ssh … bash -s` needs `-n` / `</dev/null`, or it eats the rest of that script.

## 中文摘要

这是 [aniudashi/wireless-wifi-mt7603u](https://github.com/aniudashi/wireless-wifi-mt7603u)
的 fork：保留原树，把 2014 年的 MT7603U 厂商驱动移植到现代内核，并做成
OpenWrt 24.10 的 ipk（`kmod-mt7603u-ap` / `kmod-mt7603u-sta` / `mt7603u-files`）。
AP 与 STA 两种模式都已在「官方 OpenWrt 24.10.2 虚拟机 + USB 直通真卡」上验证通过。

最坑的一点：OpenWrt 24.10 是 **6.6.93 内核 + backports 6.12.6 cfg80211**，
所以「cfg80211 API 版本」和「内核版本」不是一回事；`CPTCFG_*` 开关会改变
`struct wiphy` / `wireless_dev` / `cfg80211_ops` 的布局，门控挂错版本不会编译失败，
只会在运行时静默踩内存。移植引入了 `RTMP_CFG80211_API_VER` 把两者解耦。

详细过程与坑见 [`openwrt/REPORT.md`](openwrt/REPORT.md)。

## Licensing

Upstream ships **no LICENSE file**, and the vendor files carry a mixture of
GPL-2.0 headers and MediaTek/Ralink proprietary notices. This fork does not
change that situation: treat `DPOA/` as the vendor drop it is. The module's
`MODULE_LICENSE`/MODULE_INFO records it as `GPL`, which is what the kernel needs
to export its symbols. The packaging, harness and documentation added here are
GPL-2.0.