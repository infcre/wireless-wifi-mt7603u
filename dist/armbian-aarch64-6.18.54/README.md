# Prebuilt module — Armbian aarch64 (kernel 6.18.54-ophub)

Snapshot of the arm64 run: **STA mode only** (that board was only ever used as a
client; there is no AP build for it).

| file | mode | built on | sha256 |
|---|---|---|---|
| `mt7603u_sta.ko` | STA (wpa_supplicant) | Armbian OS 26.11.0, Amlogic S905L3B | `7ffca407b761ed8c…` |

```
vermagic: 6.18.54-ophub SMP preempt mod_unload aarch64
license:  GPL          depends: cfg80211
```

Stripped on the board itself (`strip --strip-debug`, 59.9 MB → 1.78 MB), so the
symbol table — which a module needs — is intact.

## What makes this build interesting

It is the same source as the x86_64 builds, and it is the one that forced two
fixes that **cannot** show up on x86_64 (details in
[`../../docs/debian-bringup/REPORT.md`](../../docs/debian-bringup/REPORT.md) §18):

1. **Coherent DMA pool exhaustion.**  The driver allocated ~1 MB of USB bulk
   buffers with `usb_alloc_coherent(..., GFP_ATOMIC, ...)`.  On x86 the direct
   DMA path never blocks; on the Meson SoC the USB controller is 32-bit only, so
   a non-blocking coherent allocation is routed into the per-device atomic DMA
   pool (a few hundred KB) and probe dies with
   `DMA pool exhausted for c9000000.usb`.  Fixed by using `GFP_KERNEL` on
   ARM/ARM64 — every caller is in process context anyway.
2. **Uninitialised `wiphy` band structures.**  `os_alloc_mem()` is a bare
   `kmalloc()` that does not zero, and 6.18 added `n_iftype_data` /
   `iftype_data` to `struct ieee80211_supported_band`.  `wiphy_register()`
   walked that garbage pointer and segfaulted in `modprobe`.  Fixed by zeroing
   the band structs before filling them.

## Compatibility

Only for a kernel whose release is exactly `6.18.54-ophub`:

* vermagic must match string-for-string;
* this kernel is built **without** `CONFIG_MODVERSIONS` (note the vermagic has
  no `modversions` token), so symbol CRCs are not checked — but a different
  kernel release still refuses to load it.

To rebuild for your own kernel/board:

```sh
sudo apt install linux-headers-$(uname -r)
tools/debian/build.sh sta        # same command as on x86_64; the driver has no
                                 # architecture-specific code
```

## Install

```sh
sudo modprobe cfg80211
sudo insmod /lib/modules/$(uname -r)/extra/mt7603u_sta.ko
dmesg | tail                  # rtusb init mt_drv ... CFG80211_Register
iw dev                        # interface shows up (wlan0 on classic naming)

wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
udhcpc -i wlan0               # or dhclient
```

Keep `/etc/Wireless/RT2870STA/RT2870STA.dat` with `SSID=` **empty**, `HT_BW=0`
and `BeaconLostTime=30` — the reasons are in the Debian report §11/§14.

Measured on that board (2×2 MCS15, HT20): RX 110–111 Mbit/s, TX 32–35 Mbit/s,
ping 0 % loss / 4.6 ms.