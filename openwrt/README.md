# MT7603U (360 随身 WiFi 3) for OpenWrt — 构建与使用

驱动源码：`vendor/wireless-wifi-mt7603u/DPOA/`（已适配 OpenWrt，见 `REPORT.md`）
OpenWrt 包：`owrt/package/kernel/mt7603u/`

三个包：

| 包 | 内容 | 说明 |
|---|---|---|
| `kmod-mt7603u-ap` | `mt7603u_ap.ko` | AP 模式，`AUTOLOAD` 开机自动加载 |
| `kmod-mt7603u-sta` | `mt7603u_sta.ko` | STA 模式，与 AP 包**互斥**（同一 USB ID、同一驱动名 `mt_drv`、且都导出 `AsicGetTsfTime`）|
| `mt7603u-files` | `/lib/firmware/mtk/MT7603*.bin`、`/etc/Wireless/RT2870AP|STA/*.dat`、`/etc/mt7603u/*.example` | 两个模式共用；`.dat` 已标为 conffiles |

要求：**OpenWrt 24.10.x（内核 6.6.93 / backports cfg80211 6.12.6）**。
换其它版本见文末"换版本"。

---

## 1. 构建

### 1.1 准备 SDK

```sh
# 245 MB，官方；国内换镜像 https://mirrors.aliyun.com/openwrt/releases/24.10.2/targets/x86/64/
wget https://downloads.openwrt.org/releases/24.10.2/targets/x86/64/\
openwrt-sdk-24.10.2-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst
tar --zstd -xf openwrt-sdk-*.tar.zst
cd openwrt-sdk-*/

# SDK 默认带 buildbot 的 CONFIG_ALL_KMODS=y，会让任何 package 目标先全量编一遍 kmod，关掉
sed -i "s/^CONFIG_ALL_KMODS=y/# CONFIG_ALL_KMODS is not set/; \
        s/^CONFIG_ALL_NONSHARED=y/# CONFIG_ALL_NONSHARED is not set/" .config
make defconfig
```

### 1.2 先编 mac80211 包（拿正确的 cfg80211 头文件）

`kmod-cfg80211` 来自 backports，不在内核树里，SDK 的 staging 默认**没有**这些头文件。
必须先把 OpenWrt 的 mac80211 包放进 SDK 编一遍：

```sh
# SDK 不含 package/kernel/mac80211，从 v24.10.2 源码树取（sparse clone 即可）
git clone --filter=blob:none --no-checkout --depth 1 \
    --branch v24.10.2 https://github.com/openwrt/openwrt.git owrt-src
cd owrt-src && git sparse-checkout init --cone \
    && git sparse-checkout set package/kernel/mac80211 && git checkout && cd ..
cp -a owrt-src/package/kernel/mac80211  <SDK>/package/kernel/

# 它要的 backports tarball（PKG_HASH=28ec3942…，与 OpenWrt 官方同源）
cp backports-6.12.6.tar.xz <SDK>/dl/

cd <SDK>
make package/kernel/mac80211/compile     # 约 10 分钟
ls staging_dir/target-x86_64_musl/usr/include/mac80211/net/cfg80211.h
```

### 1.3 编本包

```sh
cp -a owrt/package/kernel/mt7603u <SDK>/package/kernel/
cp -a vendor/wireless-wifi-mt7603u/DPOA <SDK>/package/kernel/mt7603u/src
cd <SDK>
make package/kernel/mt7603u/compile V=s

ls bin/targets/x86/64/packages/ | grep mt7603u
# kmod-mt7603u-ap_*_x86_64.ipk
# kmod-mt7603u-sta_*_x86_64.ipk
# mt7603u-files_*_all.ipk
```

> 包里的 `symvers/cfg80211.symvers` 是从 **24.10.2 的 cfg80211.ko** 导出的 160 个符号，
> 供 modpost 校验"我们引用的符号目标机真的导出"。想自己重生成：
>
> ```sh
> readelf -p __ksymtab_strings cfg80211.ko \
>   | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | grep -v '^$' | sort -u \
>   | awk '{printf "0x00000000\t%s\tcfg80211\tEXPORT_SYMBOL\t\n", $0}' \
>   > symvers/cfg80211.symvers
> ```
>
> **末尾那个 `\t` 不能少**：kernel 6.6 的 `modpost` 要求 5 字段（第 5 个是符号命名空间），
> 4 字段会 `FATAL: modpost: parse error in symbol dump file`。

---

## 2. 安装

```sh
scp kmod-mt7603u-*.ipk mt7603u-files_*.ipk root@router:/tmp/
ssh root@router
opkg update
opkg install kmod-cfg80211 kmod-mac80211      # 驱动依赖它
opkg install /tmp/mt7603u-files_*.ipk /tmp/kmod-mt7603u-ap_*.ipk
```

装完应当看到：

```sh
dmesg | tail
#   rtusb init mt_drv ---> ... 80211> CFG80211_Register
#   usbcore: registered new interface driver mt_drv
ip link | grep wlan
iw dev                 # Interface wlan0 ... type AP
```

`AUTOLOAD` 会把模块写进 `/etc/modules.d/`，开机由 `kmodloader` 自动加载（含 `cfg80211` 依赖）。

---

## 3. 用 AP 模式

```sh
cp /etc/mt7603u/hostapd.conf.example /etc/mt7603u/hostapd.conf   # 改 ssid/psk/channel
ip link set wlan0 up
ip addr add 192.168.50.1/24 dev wlan0
hostapd -B /etc/mt7603u/hostapd.conf
```

**让客户端能上网：两个办法**（真机上验证过的是第二种）

```sh
# 办法一：独立网段 + 第二个 dnsmasq + 单独放通防火墙
# （客户端在 192.168.50.x，与 LAN 隔离；适合访客网络）
ip addr add 192.168.50.1/24 dev wlan0
uci add_list firewall.@zone[0].device='wlan0'    # 借用 lan 区的 forward/masq
uci commit firewall && /etc/init.d/firewall reload
dnsmasq --conf-file=/dev/null -i wlan0 --bind-interfaces --port=0 \
        --dhcp-range=192.168.50.100,192.168.50.200,255.255.255.0,12h \
        --dhcp-option=3,192.168.50.1
```

### 3b. 装在真路由器上（已在一台 x86_64 OpenWrt 24.10.2 上验证）

第二条路 —— **桥进 `br-lan`**，客户端落进真正的 LAN，DHCP/防火墙/NAT 全部继承现成的，
不需要额外 dnsmasq、也不改防火墙。一体化脚本：
[`../tools/router/bring-up-ap.sh`](../tools/router/bring-up-ap.sh)。

```sh
opkg install kmod-cfg80211 kmod-mac80211 mt7603u-files_*.ipk kmod-mt7603u-ap_*.ipk

# 1) 打开接口 —— 这一步才跑 rt28xx_init（固件下载 / EFUSE 读 MAC / 校准）
ip link set wlan0 up

# 2) 删掉 OpenWrt 自动收编出来的 radio1，别让 netifd 去驱动厂商驱动
uci -q delete wireless.radio1
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.device='radio1'$/\1/p"); do
    uci -q delete wireless.$s
done
uci commit wireless

# 3) hostapd：必须“先无桥”启动（bridge= 在这个驱动上会失败），并用 -P 记 pid
setsid hostapd -P /var/run/hostapd-mt7603u.pid /etc/mt7603u/hostapd.conf \
    >/tmp/hostapd-mt7603u.log 2>&1 &

# 4) AP 起来之后再挂进 LAN 桥 —— 客户端直接用原有 dnsmasq + lan→wan NAT
ip link set wlan0 master br-lan
```

三个必须知道的坑（详见 [`REPORT.md`](REPORT.md) §3.7）：

| 坑 | 症状 | 做法 |
|---|---|---|
| hostapd `bridge=` | `Could not set channel for kernel driver` + 11× `Match already configured` | 先无桥起 AP，再 `ip link set master` |
| 残留 hostapd | 之后每次启动都同样报"信道"错误 | `hostapd -P <pidfile>`，按 **PID** 杀；busybox 的 `pkill -f` 不可靠 |
| OpenWrt 自动收编 phy | `/etc/config/wireless` 多出 `radio1`（band 猜成 5g） | 删掉，避免 netifd 操作厂商驱动 |

真机验证链（同一部手机）：`associated` → `EAPOL-4WAY-HS-COMPLETED` →
`DHCPACK 192.168.1.196` → `ip neigh` REACHABLE → 能上网；期间原有的 5GHz 上行
（`phy0-sta0`）ping 0% 丢包，未受影响。

> 以上都**不会**在重启后保留（没有 autoload 条目，hostapd 与桥接都是手工的）。
> 这是有意为之的安全设计：出问题时断电重启即可回到原状。要固化再往下做 init 脚本。

---

## 4. 用 STA 模式

```sh
opkg remove kmod-mt7603u-ap            # 与 STA 包互斥
opkg install /tmp/kmod-mt7603u-sta_*.ipk

cp /etc/mt7603u/wpa_supplicant.conf.example /etc/mt7603u/wpa_supplicant.conf   # 改 ssid/psk
ip link set wlan0 up
wpa_supplicant -B -i wlan0 -c /etc/mt7603u/wpa_supplicant.conf
udhcpc -i wlan0
```

要点：

- `/etc/Wireless/RT2870STA/RT2870STA.dat` 里的 `SSID=` 必须**留空**，否则它会钉死关联、
  覆盖 wpa_supplicant 的协商结果；
- 省电一定要关（默认开启时实测 RX 从 ~50 掉到 ~22 Mbit/s）：
  `iw dev wlan0 set power_save off`
- 信道宽度不用重载模块：改 `.dat` 的 `HT_BW`（0=20 MHz，1=40 MHz）后重开接口即可；
- `BeaconLostTime` 默认给了 30（厂商默认 4）——小值会在收信标不稳时每 ~12 秒重连一次。

实测（虚拟机 → `iperf3` 打 192.168.1.1）：TX 30.5 / RX 52.8 Mbit/s，ping 0% 丢包 5.8 ms。

---

## 5. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `insmod: unknown symbol cfg80211_*` | `kmod-cfg80211` 没装或没加载；先 `opkg install kmod-cfg80211` |
| `insmod: unknown symbol iwe_stream_add_event` / `wireless_send_event` | 用了为 Debian（有 WEXT）编的模块；OpenWrt 版必须 `-DRTMP_CFG80211_WEXT=0` 重编 |
| `exports duplicate symbol AsicGetTsfTime` | AP 与 STA 模块同时装了；卸掉另一个再重启 |
| `insmod: version magic ... should be ...` | 编它的 SDK 与目标机内核不一致（必须同 24.10.x / 同 config） |
| 驱动起来了但 `iw dev` 没有 wlan0 | 接口在打开时才创建；`ip link set wlan0 up` 或看 `dmesg` 里的 `rt28xx_init` |
| `iw dev wlan0 station dump` 为空 | 驱动未把 station 统计通过 nl80211 导出（数据面正常，与 Debian 相同）|
| 想切模式 | 先 `ip link set wlan0 down`，再 `echo -n 1-1:1.0 > /sys/bus/usb/drivers/mt_drv/unbind`，然后 `rmmod`、装另一个包/模块、重新 bind 或重启 |

> 不要在真实路由器上反复 `rmmod`：Debian 阶段有过 module-exit 路径持 RTNL + module_mutex
> 卡死整机的记录。虚拟机里可以随便试（本次也是这么验的）。

---

## 6. 换版本（非 24.10.x）

本包把两件事钉在 24.10.2 上，换版本必须同步重做：

1. **`RTMP_CFG80211_API_VER`**：看目标机的 `kmod-cfg80211` 版本，`6.6.93.6.12.6-r2` → 612；
   若是 backports 6.13/6.14 就要 613/614。
2. **`symvers/cfg80211.symvers`**：从目标机的 `cfg80211.ko` 重新导出（见 1.3 的命令），
   顺便就能看出符号有没有增减。

查看目标机实际版本：

```sh
opkg list-installed | grep -E 'cfg80211|mac80211'
modinfo cfg80211 | grep vermagic
```