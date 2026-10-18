# The Debian / Armbian bring-up

Before the OpenWrt port there was a from-scratch bring-up of the same driver on
**Debian 13 (x86_64, Linux 6.12)** and then on **Armbian (aarch64, Linux 6.18)**.
That work is what made the OpenWrt port a matter of fixing build/ABI details
rather than reverse-engineering a driver, so it is kept here.

* [`REPORT.md`](REPORT.md) — the full record (Chinese). Sanitised for
  publication: passwords, MAC addresses, per-host LAN addresses and
  campus/upstream SSIDs are placeholders; the technical content and all
  measurements are unchanged.  Highlights:

  * **Which driver, and why nothing in-tree can work** — `mt76`'s `mt7603` is
    PCIe-only, `mt7601u` refuses this chip (`asic_rev` check), so adding a
    VID/PID cannot work; the vendor DPOA tree is the only route.
  * **Four runtime bugs that compiling could not reveal**, including
    `prepare_kernel_cred(NULL)` deadlocking the machine with RTNL held, and
    channel flags mapped onto the wrong enum (`NL80211_RRF_*`) which disabled
    every channel.
  * **Two arm64-only bugs**: `GFP_ATOMIC` coherent DMA exhausting the atomic
    pool on Meson USB, and `os_alloc_mem()` handing a struct with uninitialised
    tail bytes to `wiphy_register()`.
  * **The RX mystery** — receive throughput looked like a driver defect at
    6–13 Mbit/s for a long time; the real cause was the stick sitting inside a
    metal case next to metal USB ports.  Moving it out on an extension cable
    raised RX ~7×, and the same A/B test done earlier could not see it because
    *both* cards in the comparison shared the same bad environment.
  * **Two hard operational rules**: never call the vendor's private ioctls
    (`iwpriv`) — one call wedged a host permanently — and never `rmmod` while
    the stick is bound; unbind first (`ip link set <if> down`, then
    write the bus id to `/sys/bus/usb/drivers/mt_drv/unbind`).

* [`../../dist/debian-x86_64-6.12.101/`](../../dist/debian-x86_64-6.12.101/) —
  the two modules that were verified on that box, stripped, with the
  compatibility caveat spelled out (Debian has `CONFIG_MODVERSIONS=y`, so they
  load only on that exact kernel release).
* [`../../dist/armbian-aarch64-6.18.54/`](../../dist/armbian-aarch64-6.18.54/) —
  the aarch64 STA module from the Armbian board, i.e. the build that contains the
  two arm64-only fixes described above.
* [`../../tools/debian/build.sh`](../../tools/debian/build.sh) — rebuild them for
  *your* kernel; the same script is what was used on Armbian (aarch64), since the
  driver is architecture-independent.
* [`../../tools/debian/netpeer.py`](../../tools/debian/netpeer.py) — the fixed
  length/timed TCP peer the throughput numbers were taken with, used because
  there was no `iperf3` on both ends.  Listener always on the Linux side so the
  Windows peer only makes outbound connections.

## Not included

* **The ~60 throwaway measurement scripts** from the bring-up (per-run
  association/policy-routing/throughput probes).  They were written against one
  specific LAN and are not useful without it; the report keeps their findings.
* **An AP-mode build for aarch64.**  That board was only used as a station, so
  only the STA module exists; `tools/debian/build.sh ap` builds one if needed.

## The one-line relationship to the OpenWrt port

Debian/6.12 used the kernel's own cfg80211; OpenWrt/6.6 uses *backports*
cfg80211 6.12.  The driver therefore has to be told which cfg80211 API it is
being compiled against, independently of `LINUX_VERSION_CODE` — that is
`RTMP_CFG80211_API_VER`, and it exists because of the comparison between these
two platforms.  See [`../../openwrt/REPORT.md`](../../openwrt/REPORT.md).