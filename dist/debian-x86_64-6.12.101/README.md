# Prebuilt modules — Debian x86_64 (kernel 6.12.101+deb13-amd64)

Snapshot of the Debian bring-up, published so the exact verdict can be
reproduced without rebuilding.  **Read the compatibility note before using
them** — kernel modules are not portable across kernel builds.

| file | mode | built for | sha256 |
|---|---|---|---|
| `mt7603u_ap.ko`  | AP (hostapd)      | `6.12.101+deb13-amd64` | `9aecab7be057d83d…` |
| `mt7603u_sta.ko` | STA (wpa_supplicant) | `6.12.101+deb13-amd64` | `9bdba855de45a194…` |

```
vermagic: 6.12.101+deb13-amd64 SMP preempt mod_unload modversions
license:  GPL          depends: cfg80211,usbcore
```

Stripped (`strip --strip-debug`): 61 MB → 3.3 MB, vermagic and the symbol table
left intact.

## Compatibility

These load **only** on a Debian 13 (`deb13`) amd64 kernel whose release is
exactly `6.12.101+deb13-amd64`:

* the **vermagic** must match string-for-string, and
* Debian has `CONFIG_MODVERSIONS=y`, so every symbol CRC must match as well.

Any other kernel (a point release bump, a backport kernel, Armbian, …) will
refuse them with `version magic … should be …` or
`disagrees about version of symbol …`.  That is expected, not a bug in the
driver — rebuild instead:

```sh
# tools/debian/build.sh in this repo
sudo apt install linux-headers-$(uname -r)
tools/debian/build.sh ap     # or: sta
ls /lib/modules/$(uname -r)/extra/
```

Both modules need `cfg80211` to be present (on Debian it is part of the kernel
image; on OpenWrt install `kmod-cfg80211`).  They declare the same USB ID and
driver name, so **only one can be loaded at a time**:

```sh
sudo modprobe cfg80211
sudo insmod /lib/modules/$(uname -r)/extra/mt7603u_ap.ko     # or _sta
dmesg | tail            # -> rtusb init mt_drv ... CFG80211_Register
/usr/sbin/iw dev        # -> wlanX / wlx... , type AP
```

Runtime config lives in `/etc/Wireless/RT2870AP/RT2870AP.dat` (AP) or
`/etc/Wireless/RT2870STA/RT2870STA.dat` (STA) — see
[`docs/debian-bringup/REPORT.md`](../../docs/debian-bringup/REPORT.md) §5/§11,
including the three settings that matter (`SSID=` empty, `HT_BW`,
`BeaconLostTime=30`).

> The machine these were built on has since moved to `6.12.94+deb13-amd64`, so
> they are a record of the verified 6.12.101 build rather than something you can
> drop onto that box today.