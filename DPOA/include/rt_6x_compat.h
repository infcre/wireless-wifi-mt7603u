/****************************************************************************
 * rt_6x_compat.h
 *
 * Compatibility shim: helps this 2014-era MediaTek DPO driver build against
 * modern kernels (5.x / 6.x). Include this BEFORE the kernel headers that
 * need patching.
 *
 * Port target: Debian 13 / Linux 6.12
 ****************************************************************************/
#ifndef __RT_6X_COMPAT_H__
#define __RT_6X_COMPAT_H__

#include <linux/version.h>
#include <linux/types.h>

/* ---------------------------------------------------------------------------
 * 0. Generic constant shims for identifiers removed from the kernel.
 * ------------------------------------------------------------------------ */

/* IEEE80211_NUM_BANDS was replaced by NUM_NL80211_BANDS in Linux 4.20.
 * Still referenced by include/cfg80211.h and cfg80211drv.c. */
#include <linux/nl80211.h>
#ifndef IEEE80211_NUM_BANDS
#  define IEEE80211_NUM_BANDS NUM_NL80211_BANDS
#endif

/* ---------------------------------------------------------------------------
 * 1. asm/unaligned.h was removed in Linux 6.2; use linux/unaligned.h.
 *    Older kernels only have the asm/ variant.
 * ------------------------------------------------------------------------ */
#if defined(__has_include)
#  if __has_include(<linux/unaligned.h>)
#    define RT_COMPAT_HAVE_LINUX_UNALIGNED 1
#  endif
#endif

/* ---------------------------------------------------------------------------
 * 2. procfs: create_proc_entry() and the read_proc/write_proc callbacks were
 *    removed in Linux 3.10. Provide the flag the driver can test.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 10, 0)
#  define RT_COMPAT_NO_LEGACY_PROC 1
#endif

/* ---------------------------------------------------------------------------
 * 3. init_timer() / setup_timer() removed in Linux 4.15 (timer_setup()).
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 15, 0)
#  define RT_COMPAT_TIMER_SETUP_API 1
#endif

/* ---------------------------------------------------------------------------
 * 4. daemonize() removed in Linux 4.0.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 0, 0)
#  define RT_COMPAT_NO_DAEMONIZE 1
#endif

/* ---------------------------------------------------------------------------
 * 5. kill_proc() removed in Linux 2.6.32.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 32)
#  define RT_COMPAT_NO_KILL_PROC 1
#endif

/* ---------------------------------------------------------------------------
 * 6. __devinit / __devexit / __devinitdata removed in Linux 3.8.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
#  ifndef __devinit
#    define __devinit
#  endif
#  ifndef __devexit
#    define __devexit
#  endif
#  ifndef __devinitdata
#    define __devinitdata
#  endif
#  ifndef __devexit_p
#    define __devexit_p(x) (x)
#  endif
#endif

/* ---------------------------------------------------------------------------
 * 7. get_user_pages() family changed in 4.9 (added 'gup_flags').
 *    The driver should prefer get_user_pages_fast(); flag it.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 9, 0)
#  define RT_COMPAT_NO_LEGACY_GUP 1
#endif

/* ---------------------------------------------------------------------------
 * 8. net_device->trans_start removed in 5.18.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 18, 0)
#  define RT_COMPAT_NO_TRANS_START 1
#endif

/* ---------------------------------------------------------------------------
 * 9. cfg80211 / mac80211 API drift.
 *
 * !!! IMPORTANT (added for the OpenWrt port) !!!
 *
 * The cfg80211 *API* version and the *kernel* version are two different things.
 * OpenWrt does not use the kernel's own cfg80211: it builds cfg80211/mac80211
 * from the backports tree, so an OpenWrt 6.6.93 kernel ships a 6.12.6
 * cfg80211 (kmod-cfg80211 6.6.93.6.12.6-r2).  When that driver builds against
 * the mac80211-backport headers, `#include <net/cfg80211.h>` describes the
 * 6.12 API even though LINUX_VERSION_CODE reports 6.6.93.
 *
 * Gating cfg80211 code on LINUX_VERSION_CODE alone therefore selects the WRONG
 * branch on such a system -- it compiles (both branches were written to build)
 * and then calls into cfg80211 through the wrong ABI.  Everything that depends
 * on the cfg80211/mac80211 API must be gated on RTMP_CFG80211_API_VER instead:
 *
 *     600 = 6.0 .. 6.11      612 = 6.12      613 = 6.13      614 = 6.14+
 *
 * The build may (and for OpenWrt, does) override it explicitly;
 * the OpenWrt package passes -DRTMP_CFG80211_API_VER=612.
 * ------------------------------------------------------------------------ */
#ifndef RTMP_CFG80211_API_VER
#  if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
#    define RTMP_CFG80211_API_VER 614
#  elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
#    define RTMP_CFG80211_API_VER 613
#  elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)
#    define RTMP_CFG80211_API_VER 612
#  else
#    define RTMP_CFG80211_API_VER 600
#  endif
#endif

#if RTMP_CFG80211_API_VER >= 612
#  define RT_COMPAT_KERNEL_6_12 1
#endif

/* ---------------------------------------------------------------------------
 * 10. simple_strtoul() is deprecated but still present; keep it quiet.
 * ------------------------------------------------------------------------ */
#ifndef RT_COMPAT_STRTOUL
#  define RT_COMPAT_STRTOUL(buf, end, base) simple_strtoul(buf, end, base)
#endif

/* ---------------------------------------------------------------------------
 * 11. struct file_operations lost ->read / ->write in Linux 4.14.
 *     Direct calls like `fp->f_op->write(fp, buf, len, &fp->f_pos)` must
 *     become kernel_write(). Route them through wrappers so the ~40 call
 *     sites in this driver stay untouched.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)
#  define RTMP_FILE_HAS_FOP_RW 0
#  define RTMP_FILE_WRITE(fp, buf, len)      kernel_write((fp), (buf), (len), &(fp)->f_pos)
#  define RTMP_FILE_READ(fp, buf, len)       kernel_read((fp), (buf), (len), &(fp)->f_pos)
#  define RTMP_FILE_WRITE_OK(fp)             (1)
#  define RTMP_FILE_READ_OK(fp)              (1)
#else
#  define RTMP_FILE_HAS_FOP_RW 1
#  define RTMP_FILE_WRITE(fp, buf, len)      (fp)->f_op->write((fp), (buf), (len), &(fp)->f_pos)
#  define RTMP_FILE_READ(fp, buf, len)       (fp)->f_op->read((fp), (buf), (len), &(fp)->f_pos)
#  define RTMP_FILE_WRITE_OK(fp)             ((fp)->f_op && (fp)->f_op->write)
#  define RTMP_FILE_READ_OK(fp)              ((fp)->f_op && (fp)->f_op->read)
#endif

/* ---------------------------------------------------------------------------
 * 12. set_fs() / get_fs() / mm_segment_t were removed in Linux 5.10.
 *     Since kernel_read()/kernel_write() do their own user/kernel handling,
 *     these become no-ops. KERNEL_DS also disappears with them.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#  ifndef KERNEL_DS
#    define KERNEL_DS 0
#  endif
#  ifndef USER_DS
#    define USER_DS 0
#  endif
#  ifndef mm_segment_t
#    define mm_segment_t unsigned long
#  endif
#  define RTMP_GET_FS()      (0UL)
#  define RTMP_SET_FS(x)     do { } while (0)
#else
#  define RTMP_GET_FS()      get_fs()
#  define RTMP_SET_FS(x)     set_fs(x)
#endif

/* ---------------------------------------------------------------------------
 * 13. access_ok() lost its leading "type" argument in Linux 5.0.
 *     The driver calls the 3-argument form (e.g.
 *     access_ok(VERIFY_WRITE, ptr, len)), which now expands to the
 *     2-argument macro and fails with "passed 3 arguments, but takes just 2".
 *     Route those call sites through RTMP_ACCESS_OK.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)
#  define RTMP_ACCESS_OK(type, addr, size)   access_ok((addr), (size))
#else
#  define RTMP_ACCESS_OK(type, addr, size)   access_ok((type), (addr), (size))
#endif

/* ---------------------------------------------------------------------------
 * 14. cfg80211 / nl80211 identifier renames (3.10 -> 6.x).
 *
 * These are pure renames on the kernel side, so mapping the old spellings onto
 * the new ones keeps the driver sources untouched. Only names that still exist
 * under a new spelling are mapped here; anything genuinely deleted is handled
 * at its call site.
 * ------------------------------------------------------------------------ */
#include <net/cfg80211.h>
#include <linux/ieee80211.h>	/* defines RATE_INFO_FLAGS_* */

/* nl80211 rate flags: RATE_INFO_FLAGS_40_MHZ_WIDTH -> RATE_INFO_FLAGS_40MHZ
 * (Linux 4.1); likewise for 80 MHz. Guarded with #ifdef so the mapping is a
 * no-op on modern kernels, where the old spelling still exists as an alias. */
#ifdef RATE_INFO_FLAGS_40MHZ
#  ifndef RATE_INFO_FLAGS_40_MHZ_WIDTH
#    define RATE_INFO_FLAGS_40_MHZ_WIDTH RATE_INFO_FLAGS_40MHZ
#  endif
#endif
#ifdef RATE_INFO_FLAGS_80MHZ
#  ifndef RATE_INFO_FLAGS_80_MHZ_WIDTH
#    define RATE_INFO_FLAGS_80_MHZ_WIDTH RATE_INFO_FLAGS_80MHZ
#  endif
#endif

/* survey_info: the CHANNEL_TIME_* names lost their CHANNEL_ prefix in
 * Linux 4.0 (struct fields channel_time_busy -> time_busy). */
#ifdef SURVEY_INFO_CHANNEL_TIME_BUSY
#  ifndef SURVEY_INFO_TIME_BUSY
#    define SURVEY_INFO_TIME_BUSY SURVEY_INFO_CHANNEL_TIME_BUSY
#  endif
#endif
#ifdef SURVEY_INFO_CHANNEL_TIME_EXT_BUSY
#  ifndef SURVEY_INFO_TIME_EXT_BUSY
#    define SURVEY_INFO_TIME_EXT_BUSY SURVEY_INFO_CHANNEL_TIME_EXT_BUSY
#  endif
#endif
#ifdef SURVEY_INFO_CHANNEL_TIME
#  ifndef SURVEY_INFO_TIME
#    define SURVEY_INFO_TIME SURVEY_INFO_CHANNEL_TIME
#  endif
#endif

/* ieee80211_band: the *_GHZ spellings became *_G in Linux 4.7.
 *
 * These new names are ENUM CONSTANTS, not macros, so #ifdef cannot detect
 * them -- the mapping must be keyed off the kernel version instead. */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 7, 0)
#  ifndef IEEE80211_BAND_2GHZ
#    define IEEE80211_BAND_2GHZ IEEE80211_BAND_2G
#  endif
#  ifndef IEEE80211_BAND_5GHZ
#    define IEEE80211_BAND_5GHZ IEEE80211_BAND_5G
#  endif
#endif

/* Channel flags: only TWO of them were actually removed.
 *
 * Modern kernels still provide most of the set as enum constants in
 * net/cfg80211.h with their original bit values:
 *
 *     IEEE80211_CHAN_DISABLED  = BIT(0)
 *     IEEE80211_CHAN_NO_IR     = BIT(1)
 *     IEEE80211_CHAN_RADAR     = BIT(3)
 *
 * IEEE80211_CHAN_PASSIVE_SCAN and IEEE80211_CHAN_NO_IBSS were folded into
 * IEEE80211_CHAN_NO_IR and no longer exist.
 *
 * History / why this comment is long: an earlier revision of this file mapped
 * the whole set onto NL80211_RRF_*. That is a DIFFERENT enum (request flags
 * for NL80211_ATTR_*, where NL80211_RRF_NO_IR == 1 << 7), and the kernel
 * supplies these names as enum constants rather than macros, so the "#ifndef"
 * guard never suppressed the mapping. Every channel ended up with a bogus bit
 * set, and CFG80211OS_ChanInfoGet() rejected the entire band:
 *
 *     Chan 001 (frq 2412):  not allowed!   ... through Chan 013
 *
 * These are enum constants, so #ifdef cannot detect them -- key off the
 * version instead. If a future kernel renames these, the build will fail
 * loudly here rather than silently mis-flagging channels.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 7, 0)
#  define IEEE80211_CHAN_PASSIVE_SCAN IEEE80211_CHAN_NO_IR
#  define IEEE80211_CHAN_NO_IBSS      IEEE80211_CHAN_NO_IR
#endif

/* ---------------------------------------------------------------------------
 * 16. do_gettimeofday() / struct timeval were removed in Linux 4.20
 *     (ktime_get_real_ts64() + struct timespec64).
 *
 * Instead of editing every call site, redirect the two spellings the driver
 * uses. `struct timeval` is only visible if <linux/time.h> happens to define
 * it, so guard on __kernel_old_timeval / absence of the tag.
 *
 * The driver only ever reads tv_sec and tv_usec from these values, so mapping
 * tv_usec to nanoseconds/1000 keeps the arithmetic identical.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)
#ifndef RT_COMPAT_TIMEVAL_MAPPED
#define RT_COMPAT_TIMEVAL_MAPPED 1
#define timeval timespec64
#define do_gettimeofday(tv) ktime_get_real_ts64(tv)
#endif
/* Callers want MICROseconds; timespec64 holds nanoseconds, so convert
 * explicitly rather than aliasing tv_usec to tv_nsec (a 1000x error). */
#define RTMP_TV_USEC(tv) ((tv).tv_nsec / 1000)
#else
#define RTMP_TV_USEC(tv) ((tv).tv_usec)
#endif

/* ---------------------------------------------------------------------------
 * 17. prepare_kernel_cred(NULL) is NOT usable on modern kernels.
 *
 * Linux 6.12's prepare_kernel_cred() warns and fails when the task argument is
 * NULL (see kernel/cred.c:634). The old "NULL means fall back to init_cred"
 * convenience no longer exists.
 *
 * Feeding that failure straight into override_creds() dereferences NULL in
 * atomic_inc(&new->usage). Observed on real hardware:
 *
 *   WARNING: CPU: 3 at kernel/cred.c:634 prepare_kernel_cred+0x1ae/0x1f0
 *   BUG: kernel NULL pointer dereference, address: 0000000000000000
 *   RIP: override_creds+0x18/0x30
 *   Call Trace:
 *     RtmpOSFSInfoChange+0x33/0x50 [mt7603u_ap]
 *     RTMPReadParametersHook+0x5a/0x170 [mt7603u_ap]
 *     rtmp_cfg_init+0x3b/0x100 [mt7603u_ap]
 *     rt28xx_init -> rt28xx_open -> __dev_open -> __rtnl_newlink
 *   note: NetworkManager[1172] exited with irqs disabled
 *
 * The oops happened with the RTNL lock held, so every later netlink/netdev
 * caller (ip, nmcli, sshd's reverse lookup) blocked forever.
 * Reference the init task explicitly instead.
 *
 * 2026-10 OpenWrt note: the "NULL is fatal" change landed in the 6.12 series,
 * but init_task is a valid argument on every kernel this driver supports, so
 * the explicit form is simply used from 6.6 onward rather than trying to pin
 * the exact patch release.  This matters here because OpenWrt 24.10 runs
 * 6.6.93 -- below the original 6.12 gate, yet close enough that the vendor
 * convenience argument must not be trusted.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 6, 0)
#define RTMP_PREPARE_ROOT_CREDS()   prepare_kernel_cred(&init_task)
#else
#define RTMP_PREPARE_ROOT_CREDS()   prepare_kernel_cred(NULL)
#endif

/* ---------------------------------------------------------------------------
 * 18. cfg80211 STA-side connectivity API drift.
 *
 * These only bite when CONFIG_STA_SUPPORT is defined, which is why the
 * AP-only build never surfaced them:
 *
 *   - `struct wireless_dev.sme_state` and the CFG80211_SME_* enum were
 *     removed in Linux 4.0; cfg80211 now tracks this internally, exposing
 *     `->conn` (non-NULL while an SME connect is in progress) and the
 *     `->connected` bit.
 *   - cfg80211_disconnected() gained `bool locally_generated` before gfp_t.
 *
 * The version boundaries below are best-effort for older kernels; only the
 * 6.12 target has actually been built and tested.
 * ------------------------------------------------------------------------ */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 0, 0)
#  define RTMP_WDEV_IS_CONNECTING(__wdev)  ((__wdev)->conn != NULL)
#  define RTMP_WDEV_IS_CONNECTED(__wdev)   ((__wdev)->connected)
#else
#  define RTMP_WDEV_IS_CONNECTING(__wdev)  ((__wdev)->sme_state == CFG80211_SME_CONNECTING)
#  define RTMP_WDEV_IS_CONNECTED(__wdev)   ((__wdev)->sme_state == CFG80211_SME_CONNECTED)
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
#  define RTMP_CFG80211_DISCONNECTED(__dev, __reason, __ie, __ielen, __local) \
	cfg80211_disconnected((__dev), (__reason), (__ie), (__ielen), (__local), GFP_KERNEL)
#else
#  define RTMP_CFG80211_DISCONNECTED(__dev, __reason, __ie, __ielen, __local) \
	cfg80211_disconnected((__dev), (__reason), (__ie), (__ielen), GFP_KERNEL)
#endif

/* ---------------------------------------------------------------------------
 * 19. Linux 6.13 / 6.14 / 6.15 drift (found by building on arm64 Armbian,
 *     kernel 6.18.54 -- see REPORT.md section 16).
 *
 *   - 6.13 turned most cfg80211_ops callbacks over to struct wireless_dev *;
 *     the netdev is reachable as wdev->netdev.  The callbacks that KEPT
 *     struct net_device * (verified against 6.18's own cfg80211.h) are
 *     change_virtual_intf, change_beacon, stop_ap, set_default_key,
 *     set_power_mgmt, set_cqm_* -- do not "fix" those.
 *   - set_wiphy_params gained `int radio_idx`; remain_on_channel gained
 *     `const u8 *rx_addr`; remain_on_channel and mgmt_tx take their cookie
 *     by value instead of by pointer.
 *   - 6.15 renamed del_timer_sync() to timer_delete_sync().
 *
 * The 6.13 / 6.14 split is best-effort: only 6.12 (x86_64), 6.18 (arm64) and
 * 6.6-with-6.12-backports (OpenWrt x86_64) have actually been built, and those
 * are what the gates below target.
 *
 * NOTE: every gate in this section keys off RTMP_CFG80211_API_VER, not the
 * kernel version -- see section 9 above for why that distinction exists.
 * ------------------------------------------------------------------------ */
#if RTMP_CFG80211_API_VER >= 613
#  define RTMP_CFG80211_WDEV_ARG      struct wireless_dev *wdev
#  define RTMP_CFG80211_NDEV_OF(w)    ((w)->netdev)
#else
#  define RTMP_CFG80211_WDEV_ARG      struct net_device *wdev
#  define RTMP_CFG80211_NDEV_OF(w)    (w)
#endif

#if RTMP_CFG80211_API_VER >= 614
#  define RTMP_CFG80211_COOKIE_BY_VALUE   1
#endif

/* cfg80211_new_sta() / cfg80211_del_sta() moved to struct wireless_dev * in
 * the same 6.13 change.  The driver only ever has net_device pointers, and the
 * wdev hangs off net_device->ieee80211_ptr (which the driver sets up when it
 * registers the wiphy). */
#if RTMP_CFG80211_API_VER >= 613
#  define RTMP_CFG80211_STA_WDEV(__ndev)   ((__ndev)->ieee80211_ptr)
#else
#  define RTMP_CFG80211_STA_WDEV(__ndev)   (__ndev)
#endif

/* 6.15 renamed del_timer_sync() -> timer_delete_sync().  This one really is a
 * *kernel* API, so it keeps keying off LINUX_VERSION_CODE. */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
#  define RTMP_DEL_TIMER_SYNC(t)      timer_delete_sync(t)
#else
#  define RTMP_DEL_TIMER_SYNC(t)      del_timer_sync(t)
#endif

/* ---------------------------------------------------------------------------
 * 19b. Is cfg80211 itself built with WEXT (wireless extensions) support?
 *
 * OpenWrt does NOT enable it (its mac80211 package has no CFG80211_WEXT in
 * config-y), while Debian does.  Note this is *cfg80211's* wext glue, not the
 * kernel's CONFIG_WEXT_*: when it is absent, cfg80211's iw_handler table does
 * not exist, so `iwconfig' on our netdev reports no wireless extensions.  The
 * struct layouts differ too (struct wiphy loses a pointer, struct wireless_dev
 * loses a whole sub-struct), which is why the define must match the running
 * cfg80211 -- if -DRTMP_CFG80211_WEXT disagrees with reality the driver
 * corrupts memory instead of failing loudly.
 * ------------------------------------------------------------------------ */
#if !defined(RTMP_CFG80211_WEXT)
#  if defined(CPTCFG_CFG80211_WEXT) || defined(CONFIG_CFG80211_WEXT)
#    define RTMP_CFG80211_WEXT 1
#  else
#    define RTMP_CFG80211_WEXT 0
#  endif
#endif

/* ---------------------------------------------------------------------------
 * 19c. WEXT *private* ioctls (struct iw_handler_def.private and friends).
 *
 * The kernel only declares those members when it was built with
 * CONFIG_WEXT_PRIV (include/linux/wireless.h wraps them in #ifdef), so a struct
 * literal naming .private / .num_private / .private_args / .num_private_args
 * fails to compile on a kernel without it.  OpenWrt enables no WEXT config at
 * all, which is how the STA build first hit this.
 *
 * CFG80211_WEXT is *not* the right test here: what matters is the kernel's own
 * CONFIG_WEXT_PRIV, which is the macro include/net/iw_handler.h actually wraps
 * those members in.  Ask the kernel directly -- the values arrive through
 * include/generated/autoconf.h, force-included into every module build.
 * ------------------------------------------------------------------------ */
#ifdef CONFIG_WEXT_PRIV
#  define RT_COMPAT_WEXT_PRIV 1
#else
#  define RT_COMPAT_WEXT_PRIV 0
#endif

/* ---------------------------------------------------------------------------
 * 19d. struct net_device's wext handler pointers.
 *
 * netdevice.h keeps wireless_handlers / wireless_data inside
 * #ifdef CONFIG_WIRELESS_EXT.  OpenWrt builds with no WEXT at all, so the STA
 * path that installs its iw_handler_def must be compiled out -- otherwise the
 * build dies on "'struct net_device' has no member named 'wireless_handlers'".
 * (The AP build never hits this: those lines sit under CONFIG_STA_SUPPORT.)
 *
 * Same rationale as 19c: on such a kernel there is no WEXT userspace to serve,
 * and the vendor driver's private-ioctl surface was shown to be dangerous.
 * ------------------------------------------------------------------------ */
#ifdef CONFIG_WIRELESS_EXT
#  define RT_COMPAT_NETDEV_WEXT 1
#else
#  define RT_COMPAT_NETDEV_WEXT 0
#endif

/* ---------------------------------------------------------------------------
 * 20. Coherent-DMA allocation flags (arm64 probe failure).
 *
 * The tree allocates its USB bulk buffers with GFP_ATOMIC.  On arm64 the USB
 * device is only 32-bit DMA capable, so dma-direct sends a *non-blocking*
 * coherent allocation through the per-device atomic DMA pool, which is only a
 * few hundred KB.  The MT7603U needs ~1 MB of bulk buffers, so probe dies:
 *
 *     DMA pool exhausted for c9000000.usb
 *     WARNING: CPU: 3 PID: ... at kernel/dma/pool.c:282 dma_alloc_from_pool
 *     usb_alloc_coherent <- RTMPAllocUsbBulkBufStruct <- RTMPAllocTxRxRingMemory
 *     <-- ERROR in Alloc Bulk buffer for HTTxContext!
 *     Failed to allocate memory - TxRxRing
 *     mt_drv 1-2:1.0: probe with driver mt_drv failed with error -1
 *
 * Every caller of RTUSB_URB_ALLOC_BUFFER runs in process context (probe, ring
 * setup, ROM-patch and firmware upload), which is exactly the context the
 * kernel requires for a blocking usb_alloc_coherent().  x86_64 is left with
 * GFP_ATOMIC so the already-validated path stays bit-for-bit unchanged.
 * ------------------------------------------------------------------------ */
#if defined(CONFIG_ARM64) || defined(CONFIG_ARM)
#  define RTMP_USB_COHERENT_GFP       GFP_KERNEL
#else
#  define RTMP_USB_COHERENT_GFP       GFP_ATOMIC
#endif

#define RT_COMPAT_VERSION_STRING "rt_6x_compat for Linux 6.12"

#endif /* __RT_6X_COMPAT_H__ */
