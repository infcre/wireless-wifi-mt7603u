#!/bin/sh
# Build the MT7603U vendor driver against the OpenWrt 24.10.2 SDK kernel,
# exactly the way the ipk package will build it.
#
#   owrt-build.sh AP|STA|APSTA
#
# The interesting part is the include path: OpenWrt does not use the kernel's
# own cfg80211.  Its cfg80211.ko comes from the backports 6.12.6 tree (OpenWrt
# mac80211 package), so the driver must compile against
# $(STAGING_DIR)/usr/include/mac80211{,/uapi} -- a 6.12 API on a 6.6.93 kernel.
# RTMP_CFG80211_API_VER=612 tells rt_6x_compat.h which branch to take, and
# RTMP_CFG80211_WEXT=0 matches OpenWrt's cfg80211, which has no WEXT glue
# (its config-y has no CFG80211_WEXT).  These defines change *struct layouts*,
# so a wrong value corrupts memory instead of failing to build.

MODE="${1:-AP}"
# Second argument overrides KCFLAGS.  KCFLAGS is appended after KBUILD_CFLAGS
# (kernel Makefile: "KBUILD_CFLAGS += $(KCFLAGS)"), so it is the reliable way to
# counter the kernel's -Werror, which is switched on by CONFIG_WERROR=y --
# OpenWrt enables it, Debian does not.  Pass "-Wno-error" to see every warning
# in the tree at once, or a targeted -Wno-error=<kind> list for the real build.
KCF="${2:-}"

SDK=/root/owrt-sdk/openwrt-sdk-24.10.2-x86-64_gcc-13.3.0_musl.Linux-x86_64
K="$SDK/build_dir/target-x86_64_musl/linux-x86_64/linux-6.6.93"
STG="$SDK/staging_dir/target-x86_64_musl"
TC="$SDK/staging_dir/toolchain-x86_64_gcc-13.3.0_musl/bin/x86_64-openwrt-linux-musl-"
SRC=/root/owrt-build/src/DPOA
WORK=/root/owrt-build/work-$MODE
LOG=/root/owrt-build/build-$MODE.log

[ -d "$K" ]   || { echo "no kernel at $K"; exit 1; }
[ -d "$STG/usr/include/mac80211" ] || { echo "no mac80211 headers in staging"; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$SRC" "$WORK/DPOA"

# The vendor Makefile copies the finished .ko to /tftpboot as a
# convenience for its original SDK workflow; that copy is disabled in the
# source tree (see DPOA/Makefile), so nothing to prepare here.
rm -f /tftpboot 2>/dev/null   # leftover 60 MB .ko from the Debian build, if any

# Two separate places, and the difference is not cosmetic:
#
#  * The -I paths MUST go into NOSTDINC_FLAGS.  kbuild builds its command line as
#        c_flags = ... $(NOSTDINC_FLAGS) $(LINUXINCLUDE) ... $(ccflags-y) ...
#    (scripts/Makefile.lib), so a path added to ccflags-y -- which is where the
#    vendor tree puts everything -- loses to the kernel's own include/ and the
#    driver silently compiles against the kernel's 6.6.93 net/cfg80211.h instead
#    of OpenWrt's backports 6.12.6 header.  That is exactly the ABI mismatch this
#    port is trying to avoid.  NOSTDINC_FLAGS is also exported to the kbuild
#    sub-make, so passing it here reaches the compiler.  The kernel's own
#    `NOSTDINC_FLAGS += -nostdinc` is re-stated because a command-line variable
#    cannot be appended to by the makefile.
#
#  * The -D defines are order-independent, so they stay in RTMP_EXTRA_CFLAGS
#    (ccflags-y) together with the plain defines.
#
# Only the mac80211 header tree is used, not the mac80211-backport compat shim
# tree.  The compat layer exists so mac80211 subsystem drivers can use new APIs
# on older kernels; this vendor driver only needs cfg80211's *interface*, and
# pulling the shims in does damage here:
#   * mac80211-backport/linux/unaligned.h shadows the kernel's own header and
#     gates on LINUX_VERSION_IS_LESS(), which only backport/backport.h defines;
#   * backport/backport.h #includes backport/checks.h, whose self-comparison
#     (`#if defined(CPTCFG_CFG80211) && defined(CPTCFG_CFG80211)` -- OpenWrt's
#     CONFIG_ -> CPTCFG_ rewrite turned the real check into a tautology) fires
#     the moment we define CPTCFG_CFG80211, which we must.
NOSTD="-nostdinc -I$STG/usr/include/mac80211/uapi -I$STG/usr/include/mac80211"
EXTRA="-DRTMP_CFG80211_API_VER=612 \
-DRTMP_CFG80211_WEXT=0 \
-DCPTCFG_CFG80211=1 \
-DCPTCFG_CFG80211_DEBUGFS=1 \
-DCPTCFG_CFG80211_CERTIFICATION_ONUS=1"

cd "$WORK/DPOA" || exit 1
make WIFI_MODE="$MODE" CHIPSET=mt7603u TARGET=LINUX LINUX_SRC="$K" \
     ARCH=x86_64 CROSS_COMPILE="$TC" \
     NOSTDINC_FLAGS="$NOSTD" \
     RTMP_EXTRA_CFLAGS="$EXTRA" KCFLAGS="$KCF" \
     KBUILD_MODPOST_WARN=1 > "$LOG" 2>&1
RC=$?

# KBUILD_MODPOST_WARN=1 above is deliberate: cfg80211 lives in OpenWrt's
# kmod-cfg80211, not in the kernel tree, so its symbols are absent from the
# kernel's Module.symvers and modpost cannot resolve them.  The build is only
# allowed to proceed because the target has CONFIG_MODVERSIONS disabled, so
# module loading resolves symbols by name at insmod time against the loaded
# cfg80211.ko.  Letting modpost pass is therefore NOT a guarantee -- the
# waiver is paid for by the explicit symbol cross-check below, which compares
# every undefined symbol in our .ko against the symbols cfg80211.ko actually
# exports.

echo "===== MAKE EXIT: $RC ====="
echo "===== log: $LOG ($(wc -l < "$LOG") lines) ====="
echo "===== ERROR LINES ====="
grep -nE "error:|Error [0-9]+|fatal error|undefined reference" "$LOG" | head -60
echo "===== ERROR COUNT: $(grep -cE 'error:' "$LOG") ====="
echo "===== WARNING COUNT: $(grep -cE 'warning:' "$LOG") ====="
echo "===== ARTIFACTS ====="
ls -l "$WORK/DPOA/os/linux/"*.ko 2>/dev/null
KO="$WORK/DPOA/os/linux/${MODNAME:-mt7603u_$(echo "$MODE" | tr 'A-Z' 'a-z')}.ko"
[ -f "$KO" ] || KO=$(ls "$WORK/DPOA/os/linux/"*.ko 2>/dev/null | head -1)

if [ -f "$KO" ]; then
    echo "===== ko identity ====="
    ls -l "$KO"
    file "$KO" | cut -c1-120
    modinfo "$KO" 2>/dev/null | grep -E "^(filename|license|vermagic|depends|name)" 

    echo "===== SYMBOL CROSS-CHECK vs cfg80211.ko ====="
    CFGKO=$(find "$SDK/build_dir" -path "*kmod-cfg80211*" -name cfg80211.ko 2>/dev/null | head -1)
    if [ -z "$CFGKO" ]; then
        echo "cfg80211.ko not found in the SDK build tree -- skipping (build it once with:"
        echo "  make package/kernel/mac80211/compile )"
    else
        echo "reference: $CFGKO"
        # Symbols cfg80211.ko actually exports (its __ksymtab), and the symbols
        # the kernel itself exports (Module.symvers).
        readelf -p __ksymtab_strings "$CFGKO" 2>/dev/null \
            | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | grep -v '^$' | sort -u > /tmp/cfg_exported.txt
        cut -f2 "$K/Module.symvers" | sort -u > /tmp/ksym.txt
        nm -u "$KO" 2>/dev/null | awk '{print $NF}' | sort -u > /tmp/our_undef.txt

        echo "kernel exports   : $(wc -l < /tmp/ksym.txt) symbols"
        echo "cfg80211 exports : $(wc -l < /tmp/cfg_exported.txt) symbols"
        echo "our undefined    : $(wc -l < /tmp/our_undef.txt) symbols"

        # Everything we import that the kernel does not export is our
        # responsibility to justify: it must come from a module we depend on.
        comm -23 /tmp/our_undef.txt /tmp/ksym.txt > /tmp/nonkernel.txt
        comm -23 /tmp/nonkernel.txt /tmp/cfg_exported.txt > /tmp/missing.txt
        comm -12 /tmp/nonkernel.txt /tmp/cfg_exported.txt > /tmp/used_cfg.txt

        echo "--- provided by cfg80211 ($(wc -l < /tmp/used_cfg.txt)) ---"
        cat /tmp/used_cfg.txt
        echo "--- NOT provided by kernel or cfg80211 ($(wc -l < /tmp/missing.txt)) ---"
        if [ -s /tmp/missing.txt ]; then cat /tmp/missing.txt; else echo "(none)"; fi
    fi
fi

echo "===== TAIL ====="
tail -15 "$LOG"
