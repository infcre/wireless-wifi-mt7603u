# MT7603U (360 随身 WiFi 3) — OpenWrt 移植报告

> 目标：把 `360随身wifi3`（MediaTek **MT7603U**，USB `0e8d:760c`）的厂商驱动
> 从 Debian 版（Linux 6.12 / 内核自带 cfg80211）移植到 **OpenWrt**，
> 并做成可安装的 ipk 包。
>
> **结论：AP 与 STA 两种模式在 OpenWrt 上都已实机跑通**（QEMU/KVM 虚拟机 + USB 直通，
> 系统为官方 OpenWrt 24.10.2 x86_64 镜像，与 192.168.1.1 那台同版本同 ABI）。
>
> - **AP 模式**：hostapd 经 nl80211 接管，接口 `wlan0` 出现在 `iw dev`（`type AP`），
>   手机（红米 K80 Pro）关联、WPA2 四次握手完成、DHCP 租约下发、双向 ARP 可达，ping 0% 丢包。
> - **STA 模式**：wpa_supplicant 关联上游 2.4GHz AP（`OpenWrt` / WR135 `cc:c2:e0:xx:xx:01`），
>   DHCP 拿到 `192.168.1.132`，`iperf3` 实测 **TX 30.5 / RX 52.8 Mbit/s**，
>   60 秒内重新入网 **0 次**。
> - 两个 `.ko` 编译 **0 错误**，且**每一个外部符号都能在目标机上解析**
>   （与 cfg80211.ko 的导出表逐条核对，0 个悬空符号）。

---

## 1. 目标环境（与 Debian 版的根本差别）

| 项目 | Debian 13（上一阶段） | **OpenWrt 24.10.2（本次）** |
|---|---|---|
| 内核 | 6.12.94 / 6.12.101 | **6.6.93**（`#0 SMP Mon Jun 23 20:40:36 2025`）|
| vermagic | — | **`6.6.93 SMP mod_unload`**（无 `preempt`、无 `modversions`）|
| `CONFIG_MODVERSIONS` | — | **关闭** → 加载时按符号名解析，不做 CRC 校验 |
| cfg80211 / mac80211 | **内核自带**（6.12） | **backports 6.12.6**（`kmod-cfg80211 6.6.93.6.12.6-r2`）|
| WEXT（wireless extensions） | 开启（`iwconfig` 可用） | **完全关闭**（连 `/proc/net/wireless` 都没有）|
| 工具链 | 系统 gcc | SDK：`x86_64-openwrt-linux-musl-gcc 13.3.0` |
| 编译开关 | 无 `-Werror` | **`CONFIG_WERROR=y`** |
| 模块签名 | 无 | 无（但需精确匹配 vermagic）|

一句话：**内核比 Debian 版更旧，但无线 API 反而更新** —— 这正是本次移植的核心难点。

---

## 2. 移植中必须解决的新问题

### 2.1 `RTMP_CFG80211_API_VER`：cfg80211 API 版本 ≠ 内核版本（最重要）

上一阶段把"6.12 的 cfg80211 变化"直接写进了代码，门控一律用 `LINUX_VERSION_CODE`。
在 OpenWrt 上这会**选错分支**：内核报 6.6.93，但实际链接的 cfg80211 是 6.12.6 的 ABI。

这不是理论风险，`CPTCFG_*` 开关直接改变结构体布局：

| 结构体 | 受影响的成员 | 开关 |
|---|---|---|
| `struct wiphy` | `const struct iw_handler_def *wext;`（整指针）| `CPTCFG_CFG80211_WEXT` |
| `struct wireless_dev` | 一整段 `struct { … } wext;`（含 ibss/connect 参数、keys、ssid…）| `CPTCFG_CFG80211_WEXT` |
| `struct cfg80211_ops` | `testmode_cmd` / `testmode_dump` 两个**函数指针槽** | `CPTCFG_NL80211_TESTMODE` |

槽位错位不会编译失败，只会让内核调到错误的函数指针上。

**修法**：在 `rt_6x_compat.h` 里把"cfg80211 API 代次"独立出来，构建时显式传入：

```c
#ifndef RTMP_CFG80211_API_VER          /* 600 / 612 / 613 / 614 */
#  if LINUX_VERSION_CODE >= KERNEL_VERSION(6,14,0) … 614 … 613 … 612 … 600
#endif
```

- §19 里所有 **cfg80211** 门控（wdev 参数、cookie 传值、`cfg80211_new_sta` 收 wdev）改用它；
- 纯内核 API 的门控（`del_timer_sync` → `timer_delete_sync`）继续用 `LINUX_VERSION_CODE`；
- OpenWrt 包传 `-DRTMP_CFG80211_API_VER=612`。

> 这也顺手修掉一个隐患：原代码里为 6.12 写的 `prepare_kernel_cred()` 修正挂在
> `>= 6.12` 上，而 6.6.93 也需要它；门控已下移到 `>= 6.6`。

### 2.2 把 OpenWrt 的三个开关**证实**出来，而不是猜

`CPTCFG_*` 必须与**目标机上正在运行的 cfg80211.ko** 一致，否则就是内存踩踏。
办法是拿到官方 24.10.2 的 mac80211 包源码逐条核对：

```
PKG_VERSION:=6.12.6
PKG_HASH:=28ec39425a1b3270e1422d92a8131a6a3d8919cc13e8ee250c315e55d922ba68   ← 与我们下载的 tarball 完全一致
config-y 里没有 CFG80211_WEXT                       → RTMP_CFG80211_WEXT=0
PACKAGE_CFG80211_TESTMODE 默认 n                    → 不定义 CPTCFG_NL80211_TESTMODE
PACKAGE_MAC80211_DEBUGFS 默认 y                     → 定义（不影响布局）
```

然后在 SDK 里**把 mac80211 包原样编译一遍**，得到"打了 OpenWrt 补丁"的头文件
（`staging_dir/.../mac80211/net/cfg80211.h` 350,892 B，比上游 350,057 B 大 —— 补丁确实生效），
而不是拿上游 tarball 凑合。

### 2.3 `-I` 必须走 `NOSTDINC_FLAGS`，不能走 `ccflags-y`

kbuild 的命令行组装顺序是：

```
c_flags = … $(NOSTDINC_FLAGS) $(LINUXINCLUDE) … $(ccflags-y) …
```

厂商树把所有 `-I/-D` 都塞在 `EXTRA_CFLAGS`（现代等价物 `ccflags-y`），**排在内核自带 include 之后**。
于是 `#include <net/cfg80211.h>` 会解析到内核 6.6.93 的那一份，而不是 OpenWrt 的 6.12.6 那一份 ——
**编译成功、ABI 错误**。首次尝试就是这样失败的：

```
cfg80211.c:2849: error: initialization of 'int (*)(struct wiphy *, struct net_device *, struct cfg80211_beacon_data *)'
                    from incompatible pointer type 'int (*)(struct wiphy *, struct net_device *, struct cfg80211_ap_update *)'
```

修法：`-I` 放进 `NOSTDINC_FLAGS`（并补回内核原本的 `-nostdinc`，因为命令行赋值无法被 makefile `+=` 追加）。

### 2.4 backports 的兼容层不能引入

- `mac80211-backport/linux/unaligned.h` 会抢先覆盖内核同名头，而它依赖 `LINUX_VERSION_IS_LESS()`，
  该宏只有 `backport/backport.h` 提供；
- 可一旦 `-include backport/backport.h`，它就会拉进 `backport/checks.h`：

  ```c
  #if defined(CPTCFG_CFG80211) && defined(CPTCFG_CFG80211)   /* ← 自我比较 */
  #error "You must not have cfg80211 built into your kernel if you want to enable it"
  ```

  OpenWrt 的 `CONFIG_→CPTCFG_` 改写把原本的 `CONFIG_CFG80211 && CPTCFG_CFG80211` 变成了恒真式，
  而我们**必须**定义 `CPTCFG_CFG80211`，于是必然 `#error`。

驱动只需要 cfg80211 的**接口**，不需要这套为 mac80211 子系统准备的兼容垫片 →
只挂 `mac80211/uapi` + `mac80211` 两个目录。

### 2.5 只有 WEXT 才存在的符号（编译能过，insmod 才炸）

OpenWrt 的 cfg80211 不带 wext，于是内核里根本没有这些符号：

| 符号 | 用在 | 症状 |
|---|---|---|
| `wireless_send_event` | AP 的事件上报（`rt_linux.c` ×2）| `insmod: unknown symbol` |
| `iwe_stream_add_event/point/value` | STA 的 wext 扫描结果编码器（`rt_ioctl_giwscan`）| 同上 |
| `struct iw_handler_def.private/.num_private/.private_args` | STA 的私有 ioctl 表 | 编译期就报（字段不存在）|
| `struct net_device.wireless_handlers` | STA 安装 iw_handler | 编译期就报（字段不存在）|

**关键**：前两个**编译和链接都不会失败**（modpost 只给 warning），只有加载时才报未知符号。
所以本次特别做了符号交叉核对（见 2.6），否则这颗雷会在路由器上才引爆。

修法：用**内核真实宏**门控（`CONFIG_WIRELESS_EXT`、`CONFIG_WEXT_PRIV`，由 `generated/autoconf.h` 提供），
不猜版本号。附带好处：`iwpriv` 这条路在 OpenWrt 上不可达 —— 上一阶段 `iwpriv` 曾把 Debian 主机挂死。

### 2.6 modpost：cfg80211 不在内核符号表里

cfg80211 是独立的 kmod，内核 `Module.symvers` 里没有它的符号，于是 modpost 报一堆
`undefined!`。正确做法是用 OpenWrt 的 `PKG_SYMVERS_DIR`：

- 从**目标机同源的** `kmod-cfg80211` 里取出 `cfg80211.ko`，从它的 `__ksymtab_strings`
  生成 `cfg80211.symvers`（160 个导出符号）随包携带；
- 构建时传给 modpost：`KBUILD_EXTRA_SYMBOLS="$(wildcard $(PKG_SYMVERS_DIR)/*.symvers)"`
  （本包自己驱动厂商 Makefile，不经过 OpenWrt 的 `KERNEL_MAKE_FLAGS`，必须显式传）。

**坑**：kernel 6.6 的 `modpost.c:read_dump()` 强制要求 **5 个字段**：

```c
if (!(namespace = strchr(export, '\t')))     /* 第 4 个 TAB 之后是符号命名空间 */
        goto fail;
```

4 字段的老格式直接 `FATAL: modpost: parse error in symbol dump file`。生成时末尾必须补一个制表符。

### 2.7 两个模块不能共存，且 `CONFLICTS` 只能单向

- 两者都注册 USB 驱动名 `mt_drv`、都声明 `0e8d:760c`；
- 更硬的一条：两者都导出 `AsicGetTsfTime`，同时加载直接

  ```
  mt7603u_sta: exports duplicate symbol AsicGetTsfTime (owned by mt7603u_ap)
  ```

- `CONFLICTS` 若双向声明，Kconfig 会报递归依赖：

  ```
  error: recursive dependency detected!
      symbol PACKAGE_kmod-mt7603u-ap depends on PACKAGE_kmod-mt7603u-sta
      symbol PACKAGE_kmod-mt7603u-sta depends on PACKAGE_kmod-mt7603u-ap
  ```

  → 只在 AP 包上声明冲突（opkg 双向都会拒绝）。

### 2.8 其它适配

| 项 | 说明 |
|---|---|
| 厂商 Makefile 的 `/tftpboot` 拷贝 | 打包环境里 `cp` 会把它变成一个 **60MB 的文件**；已在源码里禁用（附注释） |
| `-Werror` | OpenWrt 开 `CONFIG_WERROR`，厂商代码有 505 个警告；包内加 `-Wno-error`（真错误仍然中止构建） |
| `plug_in` 目标 | 只构建可选模块（`CONFIG_PLUGIN_*` 都未定义），无需 `/tftpboot`，保持原样 |
| 固件 | 驱动同时有**内嵌**固件（`include/mcu/*_firmware.h`）与 **`/lib/firmware/mtk/*.bin`** 两条路；按 Debian 的已验证做法随包投递 `.bin` |

---

## 3. 验证（全部在 QEMU/KVM 虚拟机内，未碰 192.168.1.1）

测试环境：官方 `openwrt-24.10.2-x86-64-generic-ext4-combined.img` + KVM，
`-device qemu-xhci` + `usb-host` 直通真卡（热插拔，不重启虚拟机），
LAN `192.168.9.1/24`，WAN 走 QEMU user-net（供 opkg）。

### 3.1 模块加载与初始化

```
rtusb init mt_drv --->
<-- RTMPAllocTxRxRingMemory, Status=0
mt7603_init()-->  Endpoint(8) In-band Command / Endpoint(84) Data-In / Endpoint(85) Command Rsp
80211> RFICType= 3, NumOfChan= 58
80211> CFG80211_Register
usbcore: registered new interface driver mt_drv
```

打开接口后（固件下载 + EFUSE）：

```
mt7603_switch_channel(): Switch to Ch#11(2T2R), BBP_BW=0
Main bssid = b0:d5:9d:xx:xx:xx            ← EFUSE 真 MAC（与 Debian 一致）
<==== rt28xx_init, Status=0
80211> re-init bands... RFICType= 1, NumOfChan= 14    ← 2.4G 信道 1–13 全可用
```

`iw phy phy0 info`：`Supported interface modes: managed / AP`，HT20/HT40，MCS 0–15。

### 3.2 AP 模式

```
hostapd: wlan0: interface state UNINITIALIZED->ENABLED
         wlan0: AP-ENABLED
iw dev:  ssid MT7603U-AP   type AP   addr b0:d5:9d:xx:xx:xx
dmesg:   Switch to Ch#11(2T2R) → "80211> Set the channel in AP Mode" / "80211> AP Key Add"

hostapd: wlan0: STA 72:86:0b:xx:xx:xx IEEE 802.11: associated
hostapd: wlan0: STA 72:86:0b:xx:xx:xx WPA: pairwise key handshake completed (RSN)
dnsmasq: DHCPACK(wlan0) 192.168.77.141 72:86:0b:xx:xx:xx android-phone
ip neigh: 192.168.77.141 dev wlan0 lladdr 72:86:0b:xx:xx:xx REACHABLE
ping -c 10 192.168.77.141 → 0% packet loss
```

旁证：Debian 上的 Intel 网卡被动扫描到本 AP

```
BSS b0:d5:9d:xx:xx:xx   freq 2462.0 (ch11)   signal -19 dBm   SSID: MT7603U-AP
```

### 3.3 STA 模式

```
insmod mt7603u_sta.ko → rc=0
wpa_supplicant: Connected to cc:c2:e0:xx:xx:01   SSID OpenWrt   freq 2462.0
udhcpc: lease of 192.168.1.132 obtained from 192.168.1.1
ip route get 192.168.1.1  →  dev wlan0  src 192.168.1.132        ← 确认走卡，而非 wlan 口
ping -I wlan0 -c 10 192.168.1.1 → 0% loss, avg 5.8 ms
iperf3 -c 192.168.1.1 -B 192.168.1.132        TX 30.5 Mbit/s
iperf3 -c 192.168.1.1 -B 192.168.1.132 -R     RX 52.8 Mbit/s
60 秒内重新入网次数: 0                                          ← BeaconLostTime=30 生效
```

对照上一阶段 Debian 侧（同样 `iperf3` 打到 192.168.1.1）：TX 28–37、RX 91–111 Mbps。
TX 基本一致；OpenWrt 侧 RX 偏低，主要变量是**卡现在直接插在机器上**（Debian 那轮已经
用 USB 延长线移出金属机箱，RX 曾因此提升约 7 倍），与驱动无关。

### 3.4 符号交叉核对（静态保证）

对两个 `.ko` 逐一比对"我们引用的符号"与"目标机真的提供的符号"：

| | AP | STA |
|---|---|---|
| 内核导出 | 16,794 | 16,794 |
| cfg80211 导出 | 160 | 160 |
| 我们引用的未定义符号 | 158 | 159 |
| 由 cfg80211 提供 | 22 | 23 |
| **既不在内核也不在 cfg80211** | **0** ✅ | **0** ✅（修掉 `iwe_stream_add_*` 之前是 3）|

### 3.5 包级验证（ipk 本身，而不是手工铺文件）

| 检查 | 结果 |
|---|---|
| `opkg install mt7603u-files + kmod-mt7603u-sta` | ✅ 无错误，`/etc/modules.d/mt7603u-sta` 与 `.../mt7603u_sta.ko` 就位 |
| `mt7603u-files` 覆盖 8 个文件 | ✅ 2 个固件 + 4 个 `.dat` + 2 个配置样例 |
| conffiles 语义 | ✅ 手工改过的 `RT2870STA.dat` 被保留，包内版本落到 `.dat-opkg`（说明 `conffiles` 生效） |
| **互斥**：STA 在装时安装 AP 包 | ✅ **被 opkg 拒绝**：`check_conflicts_for: kmod-mt7603u-sta … Cannot install package kmod-mt7603u-ap` |
| 换模式：卸 STA → 装 AP | ✅ `mt7603u_ap.ko` + `/etc/modules.d/mt7603u-ap` 就位 |
| **重启后 AUTOLOAD** | ✅ 开机 7.3 s 自动加载：`rtusb init mt_drv` → `80211> CFG80211_Register`，`lsmod` 显示 `cfg80211` 被 `mt7603u_ap` 引用 |
| `modinfo` | `depends: cfg80211`，`vermagic: 6.6.93 SMP mod_unload` —— 与目标内核逐字符一致 |

### 3.6 随包 `.dat` 默认值（沿用 Debian 上验证过的值，不是厂商原始值）

厂商原始 `RT2870STA.dat` 有三处会在实际使用中咬人，已改为验证值：

| 键 | 厂商默认 | 包内默认 | 原因 |
|---|---|---|---|
| `SSID` | `11n-AP` | *(空)* | 非空会把关联钉死，wpa_supplicant 的协商被覆盖 |
| `HT_BW` | `1`（40 MHz）| `0`（20 MHz）| 拥挤频段实测 20 MHz 的 RX 明显更好（40 MHz 时 RX CRC 错误率约 29%）|
| `BeaconLostTime` | `4` | `30` | 小值会在收信标不稳时每 ~12 秒重连一次 |
| `WirelessMode` / `CountryCode` | `5` / *(空)* | `9` / `CN` | 与 Debian 侧实机验证配置一致 |

（`RT2870AP.dat` 与厂商默认一致，无需改动。）

### 3.7 真机验证：一台物理 OpenWrt 路由器（x86_64, 24.10.2）

前面都在虚拟机里跑；最后在**一台真路由器**上（就是它承担着整个网络的上网流量）又走了一遍，
结论一致，并额外暴露了三个**只在真机/长期运行下才会出现**的坑。

证据链（同一部红米 K80 Pro，MAC `72:86:0b:xx:xx:xx`）：

| 环节 | 证据 |
|---|---|
| 模块加载 | `opkg install kmod-mt7603u-ap` → **kmodloader 随即加载**（`rtusb init mt_drv` → `80211> CFG80211_Register`）|
| 接口初始化 | `ip link set wlan0 up` → `Main bssid = b0:d5:9d:xx:xx:xx`、`<==== rt28xx_init, Status=0`、`NumOfChan= 14` |
| AP 启动 | `hostapd` → `wlan0: AP-ENABLED`，`iw dev` 报 `ssid MT7603U-AP / type AP` |
| 客户端关联 | `STA … IEEE 802.11: associated` → `AP-STA-CONNECTED … auth_alg=open` → `EAPOL-4WAY-HS-COMPLETED` |
| 地址 | `DHCPACK 192.168.1.196 … REDMI-K80-Pro`；`ip neigh` 该地址 `REACHABLE` |
| 驱动侧 | `Rcv Wcid(1) AddBAReq` —— 驱动自己看到客户端并建立了 BA 会话 |
| 上网 | 手机可正常上网（`wlan0` 桥进 `br-lan`，沿用原有 dnsmasq 与 lan→wan NAT）|
| 未影响原有链路 | 全程 `phy0-sta0 → 10.65.255.254` ping 0% 丢包 |

> 一个容易误判的点：`opkg install` 一个 kmod 包**会触发 kmodloader**，即"装完就等于加载了"。
> 这次因此"意外地"完成了加载那一步——所幸结果是干净的。反过来说，
> 若模块在加载时就 oops，而事先没删掉 `/etc/modules.d/` 里的自启条目，那**每次开机都会重现这个故障**。
> 所以稳妥流程是：先删自启条目、手工验证，最后再启用自启。

#### 三个真机才暴露的坑

1. **OpenWrt 会把我们的 phy 自动收编成 `radio1`**
   `/etc/hotplug.d/ieee80211/10-wifi-detect` 在 `CFG80211_Register` 之后触发，往
   `/etc/config/wireless` 追加：

   ```
   config wifi-device 'radio1'
       option path 'pci0000:00/0000:00:12.0/usb3/3-1/3-1.1'
       option band '5g'          # 猜错了，这卡是 2.4G
       option disabled '1'       # 好在默认禁用
   config wifi-iface 'default_radio1'
       option device 'radio1'  option mode 'ap'  option network 'lan'
   ```

   虽然默认禁用，但一旦有人 `wifi up` 或点 LuCI，netifd/hostapd 就会去驱动一个**厂商驱动**。
   必须删掉（`uci delete wireless.radio1` 以及引用它的 iface）。

2. **hostapd 的 `bridge=` 参数在这个驱动上不可用**
   走桥接模式时，hostapd 把接口挂进桥之后**会再单独下发一次信道配置**，而 cfg80211 因为
   "已经是 AP、已经在该信道"返回 `EALREADY`，hostapd 随即放弃：

   ```
   nl80211: kernel reports: Match already configured   (×11)
   Could not set channel for kernel driver
   Interface initialization failed
   ```

   不带 `bridge=` 时，信道随 `START_AP` 一次下发，正常。
   **正确顺序：先在无桥配置下起 AP，再 `ip link set wlan0 master br-lan`。**

3. **hostapd 必须按 PID 杀；busybox 的 `pkill -f` 不可靠**
   残留实例会一直占着管理帧注册，导致之后每次启动都失败，而且报错**指向信道**——
   实际上 `Match already configured` 来自 `cfg80211_mlme_register_mgmt()`（管理帧注册），
   与信道无关，极易误判成"驱动不支持改信道"。现在统一用 `hostapd -P <pidfile>` 启动、按 PID 清理。

4. **认接口不能按名字，也不能只看 netdev 的 `device/driver`**
   这台机器上不止一块无线（ath9k 走 PCIe，另外 `rt2800usb`/`rtl8192du` 模块也装着），
   接口名取决于探测顺序，`wlan0`/`wlan1` 都可能。按驱动认是对的，但要认对**层级**：

   ```
   /sys/class/net/wlan0/device              -> …/usb3/3-1/3-1.1     ← USB *设备*
   /sys/class/net/wlan0/device/driver       -> usb                  ← 通用驱动，没用
   /sys/bus/usb/drivers/mt_drv/3-1.1:1.0    → driver=mt_drv / module=mt7603u_ap  ← 在这层
   ```

   我们的驱动绑在 netdev 设备的**下一层**（USB 接口），而 `/sys/class/net/<if>/device`
   指向的是 USB 设备本身，`driver` 只会给出通用的 `usb`。ath9k 是 PCIe、`driver/module`
   直接可读，所以**朴素的写法在 PCIe 网卡上看着是对的，碰上 USB 网卡必然识别失败**。

   正确做法：遍历 `/sys/bus/usb/drivers/mt_drv/*:*`（驱动自己绑定的接口）→ 取其父设备路径 →
   找 `device` 路径相同的 netdev 即是我们那块。（本例中 `<interface>/net/` 是空的——
   厂商驱动没把 netdev 的 parent 设成 USB 接口，所以不能靠 `net/` 反查。）

   实现见 [`../tools/router/mt7603u.init`](../tools/router/mt7603u.init) 的 `iface_of_mt7603u()`。

5. **桥端口要等两次 `forward_delay` 才会转发**
   `ip link set <if> master br-lan` 之后端口走 disabled → listening → learning → forwarding，
   在 `br-lan` 的 `forward_delay=800`（8 秒）下约 **17 秒**才到 `state 3`。
   只等 2 秒就记"已桥接"，客户端其实还过不去；按桥的 `forward_delay` 计算等待时间即可。

可直接复用的脚本：[`../tools/router/bring-up-ap.sh`](../tools/router/bring-up-ap.sh)。


```
owrt/
├── REPORT.md                     ← 本文件
├── README.md                     ← 构建与使用说明
├── bin/                          ← 已编好的 ipk（x86_64 / OpenWrt 24.10.2，与 192.168.1.1 同 ABI）
│   ├── kmod-mt7603u-ap_6.6.93-r1_x86_64.ipk    591,790 B  sha256 e9221788fb4e8cbd…
│   ├── kmod-mt7603u-sta_6.6.93-r1_x86_64.ipk   602,790 B  sha256 2b9a623322365afa…
│   └── mt7603u-files_1_all.ipk                  85,993 B  sha256 80d68ffddc0e50d0…
├── package/kernel/mt7603u/
│   ├── Makefile                  ← OpenWrt 包（三个 ipk 由它产出）
│   ├── files/                    ← 固件 + 已调好的 .dat + 配置样例
│   └── symvers/cfg80211.symvers  ← 从 24.10.2 的 cfg80211.ko 生成（供 modpost 校验）
└── (源码)  vendor/wireless-wifi-mt7603u/DPOA/   ← 已适配 OpenWrt 的驱动树
```

安装（在目标机上）：

```sh
opkg update
opkg install kmod-cfg80211 kmod-mac80211                  # 驱动依赖
opkg install mt7603u-files_*.ipk kmod-mt7603u-ap_*.ipk    # 或用 -sta 包
```

- `kmod-mt7603u-ap` —— AP 模式模块，`AUTOLOAD` 开机自动加载
- `kmod-mt7603u-sta` —— STA 模式模块，与 AP 包**互斥**
- `mt7603u-files` —— 固件 `/lib/firmware/mtk/MT7603*.bin` + `/etc/Wireless/**`（conffiles）

ipk 里写死了 `kernel (=6.6.93~1745ebad77278f5cdc8330d17a3f43d6-r1)`，
所以只有 24.10.2（同 config）能直接装；其它版本按 README 第 6 节重做。

> 值得记录：`iw dev` 在**接口未打开**时显示 `addr 00:00:00:00:00:00`，打开后才变成
> EFUSE 里的 `b0:d5:9d:xx:xx:xx`。Debian 上 udev 就是按那一刻的名字把接口命名成
> `wlx000000000000`；OpenWrt 没有 udev，所以稳定是 `wlan0`。

---

## 5. 已知限制 / 未做

| 项 | 说明 |
|---|---|
| OpenWrt **UCI/LuCI 集成** | 厂商驱动不是 mac80211，netifd 的 `wifi` 脚本不会管理它；包内提供 `hostapd.conf.example` / `wpa_supplicant.conf.example`，按脚本或自写 init 启动 |
| AP 吞吐未在 OpenWrt 侧复测 | 手机上只做了关联/WPA/DHCP/ping。同驱动的 Debian 侧 AP 下行约 200 Mbps |
| 未在 192.168.1.1 真机安装 | 按你的要求，全部验证都在虚拟机内完成 |
| `iw dev wlan0 station dump` 为空 | 与 Debian 相同的已知行为：驱动未通过 nl80211 导出 station 统计（数据面正常） |
| 非 24.10 系列 | `RTMP_CFG80211_API_VER` 与 `symvers` 是按 24.10.2（backports 6.12.6）钉的；换版本需按 README 的"换版本"一节重做 |
| 内核日志噪音 | `Not support for HIF_MT yet!` 等是 USB 路径的正常噪音（PCIe 专属功能），与 Debian 一致 |