# v0.1.0 — MT7603U on OpenWrt 24.10 (and the Debian/Armbian bring-up behind it)

Port of the MediaTek **MT7603U** vendor driver (360 随身WiFi 3, USB `0e8d:760c`)
from the original 2014 Linux 3.10 drop to modern kernels, plus OpenWrt packages
and the tooling/reports used to verify it.

## Verified on

| Platform | Kernel | What was tested |
|---|---|---|
| OpenWrt 24.10.2 x86_64 (`r28739`, `kmod-cfg80211 6.6.93.6.12.6-r2`) | 6.6.93 | AP: hostapd + real client (WPA2, DHCP, ping 0% loss). STA: wpa_supplicant, DHCP, `iperf3` TX 30.5 / RX 52.8 Mbit/s, 0 re-associations in 60 s. Package install + reboot autoload. |
| Debian 13 x86_64 | 6.12.101 | AP (~200 Mbit/s down, 2×2 HT40) and STA; the module in this release is that build. |
| Armbian aarch64 (Amlogic S905L3B) | 6.18.54-ophub | STA: associates on boot, RX 110 / TX 34 Mbit/s. The aarch64 binary in this release is that build. |

Both modules build with **0 errors** and, on OpenWrt, with **0 unresolved
symbols** (every import exists in that kernel's or `cfg80211.ko`'s export table).

## Assets

| file | for | size |
|---|---|---|
| `kmod-mt7603u-ap_6.6.93-r1_x86_64.ipk` | OpenWrt 24.10.2 x86_64 — AP mode | 591 KB |
| `kmod-mt7603u-sta_6.6.93-r1_x86_64.ipk` | OpenWrt 24.10.2 x86_64 — STA mode | 602 KB |
| `mt7603u-files_1_all.ipk` | firmware + `/etc/Wireless/*.dat` (both modes) | 86 KB |
| `mt7603u_ap.ko` | Debian 13, `6.12.101+deb13-amd64` — AP mode | 3.3 MB |
| `mt7603u_sta.ko` | Debian 13, `6.12.101+deb13-amd64` — STA mode | 3.4 MB |
| `mt7603u_sta.ko` (aarch64) | Armbian, `6.18.54-ophub` (S905L3B) — STA mode | 1.8 MB |

SHA256:

```
e9221788fb4e8cbd134e251733c4974017ccba527ba15f9b98ae2211f1602c92  kmod-mt7603u-ap_6.6.93-r1_x86_64.ipk
2b9a623322365afae9ff4e5242d234528757a757c847ee4079467073b04eee80  kmod-mt7603u-sta_6.6.93-r1_x86_64.ipk
80d68ffddc0e50d0dc3b33c91f096e704c4c1b1c7f0d6249c6cd22570b2c7644  mt7603u-files_1_all.ipk
9aecab7be057d83dbf9ea1a6fc2adabc49ac0bf1bfca4ef061658310cd168851  mt7603u_ap.ko
9bdba855de45a194ce3128ebd2452f58572762f9453fcc63a4fd1d3408f400a2  mt7603u_sta.ko
7ffca407b761ed8cbec8541bb3b18ce60ce58108e366012eeaba06f0ca6cdc51  mt7603u_sta.ko (aarch64)
```

## Install — OpenWrt

```sh
opkg update
opkg install kmod-cfg80211 kmod-mac80211
opkg install mt7603u-files_1_all.ipk kmod-mt7603u-ap_6.6.93-r1_x86_64.ipk

ip link set wlan0 up
iw dev                  # type AP, MAC read from EFUSE
```

* One mode at a time: both modules claim USB `0e8d:760c`, register the driver name
  `mt_drv`, **and export the same symbol**, so they cannot coexist. The AP package
  declares `Conflicts:` on the STA one.
* The ipks are tied to `kernel (=6.6.93~1745ebad77278f5cdc8330d17a3f43d6-r1)`,
  i.e. a stock 24.10.2 build of that target. Other kernels/versions: rebuild
  (`openwrt/README.md` §6).
* This is a vendor cfg80211 driver, not mac80211 — OpenWrt's `wifi`/netifd scripts
  do not manage it. Use hostapd / wpa_supplicant with the example configs in the
  tree, or your own init script.

## Install — Debian

```sh
sudo modprobe cfg80211
sudo insmod /lib/modules/$(uname -r)/extra/mt7603u_ap.ko     # or _sta
dmesg | tail        # rtusb init mt_drv ... CFG80211_Register
```

Debian has `CONFIG_MODVERSIONS=y`: these two `.ko` files load **only** on
`6.12.101+deb13-amd64`. Any other kernel — including a later 6.12 point release —
needs a rebuild: `tools/debian/build.sh ap|sta`.

## What was hard

OpenWrt pairs a **6.6.93 kernel with backports 6.12.6 cfg80211**, so the wireless
API is *newer* than the kernel. Gating cfg80211 code on `LINUX_VERSION_CODE`
selects the wrong branch, and since `CPTCFG_*` changes the layouts of
`struct wiphy` / `wireless_dev` / `cfg80211_ops`, "wrong branch" is silent memory
corruption rather than a build failure. The port adds
`RTMP_CFG80211_API_VER` to decouple the two, drops every WEXT assumption
(OpenWrt's cfg80211 has no WEXT: three symbols simply do not exist, and the
failure only shows up at `insmod`), and pins the header search order via
`NOSTDINC_FLAGS`.

Full write-ups, with evidence and the dead ends:

* [`openwrt/REPORT.md`](https://github.com/infcre/wireless-wifi-mt7603u/blob/master/openwrt/REPORT.md)
* [`docs/debian-bringup/REPORT.md`](https://github.com/infcre/wireless-wifi-mt7603u/blob/master/docs/debian-bringup/REPORT.md)

## Known limitations

* No UCI/LuCI integration (see above).
* `iw dev <if> station dump` is empty — the driver does not export station stats
  over nl80211; data plane is fine.
* Kernel log has benign `Not support for HIF_MT yet!` lines (PCIe-only features
  being probed on the USB path).
* The aarch64 module is STA-only — that board was only ever used as a client;
  `tools/debian/build.sh ap` builds an AP one.

## Licensing

Upstream ships no LICENSE file; the vendor tree carries a mix of GPL-2.0 headers
and MediaTek/Ralink proprietary notices. This release adds packaging and
documentation only and does not change that. The module reports `license: GPL`,
which is what the kernel requires to export its symbols.
