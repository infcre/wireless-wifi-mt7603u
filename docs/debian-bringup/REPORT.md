> **这份文档已脱敏后公开。** 原始记录里的路由器 root 口令、真实设备 MAC、
> 局域网内各主机的具体地址、校园网与上游 AP 的 SSID 都已替换成占位值
> （`<redacted>` / `xx:xx` / `192.168.1.10` 等）。技术结论、引脚依据、测量数据未改动。
>
> Sanitised for publication: the router password, real MAC addresses, per-host LAN
> addresses and the campus/upstream SSIDs were replaced with placeholders. The
> engineering conclusions and measurements are unchanged.

---
# 360 随身 WiFi 3 → Linux 移植最终报告

> 目标：让 `360随身wifi3`（MediaTek MT7603U，`0E8D:760C`）在 Debian 13 / **Linux 6.12.101** 上工作
>
> **结论：完全成功，AP 与 STA 两种模式都已跑通。**
> - **AP 模式**：hostapd 经 nl80211 接管，手机（红米 K80 Pro）关联、DHCP、NAT 上网全部正常，2×2 40MHz 实测下行 ~200 Mbps。
> - **STA 模式**：作为客户端关联上游 2.4GHz AP（WPA2-PSK），已对接 NetworkManager 并做成开机自启（重启验证通过）；2×2 MCS15。
>   单跳 iperf3（卡 →WR135→ 有线 →192.168.1.1）最终实测：**RX 50–94 Mbps**（4 流 96）、**TX 28–43 Mbps**，ping 0% 丢包 / 1.9 ms。
> - **RX 曾长期只有 6–13 Mbps，已找到真因并解决**：不是驱动、也不是 WR135，
>   而是**这张 USB 卡被塞在金属机箱内部、紧邻金属 USB 口**。用户加 USB 延长线把卡移出机箱
>   （并把 AP 从 ch1 换到 ch11）后，RX **提升约 7 倍**。详见第 17 节（含对第 15 节结论的更正）。
> - **可移植性（已实证）**：同一份源码在 **aarch64 + Linux 6.18.54（Armbian，Amlogic S905L3B）**
>   上**编译与运行都已通过** —— 插卡即自动加载/关联，实测 RX 110 Mbps、TX 34 Mbps。见第 16、18 节。
>
> STA 部分见第 9–15 节。

---

## 1. 最终状态

| 项目 | 状态 |
|---|---|
| 模块编译 | ✅ `MAKE_EXIT=0`，0 错误 |
| 模块加载 | ✅ `insmod rc=0`，无崩溃 |
| USB 绑定 | ✅ `mt_drv` 绑定 `1-4:1.0` |
| 固件下载 | ✅ `WiFI FW Download Success` |
| EFUSE 读取 | ✅ 取得真实 MAC `b0:d5:9d:xx:xx:xx` |
| 射频校准 | ✅ Ch4–Ch11 扫描完成 |
| 信道可用性 | ✅ 2.4GHz **1–13 全部可用**（Ch14 按 CN 监管域正确禁用） |
| AP 模式 | ✅ hostapd 经 nl80211 接管 |
| **客户端关联** | ✅ **红米 K80 Pro 成功连接** |
| DHCP | ✅ 分发 `192.168.50.141` |
| NAT 上网 | ✅ 转发至内置 Intel 卡 |
| 内存越界 | ✅ 已修复，`field-spanning` 警告归零 |

实测日志：
```
DHCP leases:
1791398112  72:86:0b:xx:xx:xx  192.168.50.141  android-phone

ip neigh: 192.168.50.141 lladdr 72:86:0b:xx:xx:xx REACHABLE
dmesg:    Rcv Wcid(1) AddBAReq / Start Seq = 00000002
```

---

## 2. 设备身份

| 项目 | 值 | 证据 |
|---|---|---|
| 芯片 | **MediaTek MT7603U** | `mtkwlux.inf`: `OS61_MTKWLAN_7603_360.ndi, USB\VID_0E8D&PID_760C` |
| VID:PID | `0E8D:760C` | `Get-PnpDevice` |
| bcdDevice | `0001`，speed `480 Mbps` | USB 枚举 |
| 接口 | `ff/ff/ff`，8 个 Bulk 端点 | sysfs |
| ENDPOINT 布局 | `ep_04..09` Bulk OUT + `ep_84/85` Bulk IN | **与驱动硬编码完全一致**（验证通过）|

---

## 3. 为什么必须自己移植

- `mt76` 的 `mt7603` 子驱动**只有 PCIe**，无 `mt7603/usb.c`
- `mt7601u` 只匹配 `148F:760C`，且 probe 校验 `asic_rev == 0x7601` 否则 `-ENODEV`
- → **加 VID/PID 绝无可能工作**；只能移植厂商 DPO 驱动

源码：`github.com/aniudashi/wireless-wifi-mt7603u`（DPOA，MediaTek 厂商驱动，483 文件）

---

## 4. 移植工作量（Linux 3.10 → 6.12）

源码 232 处版本门控**最高仅到 3.10.0**。移植共修 **40+ 处**：

### 编译期
`SUBDIRS→M`、`asm/unaligned.h`、`__inline` 污染内核 `asm_inline`、`mm_segment_t`/`set_fs`、
`f_op->read/write`、`access_ok` 参数、`daemonize`、`f_dentry`、`init_timer`、
`do_gettimeofday`/`struct timeval`、`current->pids[]`、`skb->tail/head/end` 偏移化、
`IEEE80211_NUM_BANDS`、`-Werror=date-time`、非 void 函数缺返回、指针层级错误、
**cfg80211 ops 表 15 个适配器**（`change_beacon`/`stop_ap`/key 操作 `link_id`/`mgmt_tx` 参数结构体/
`update_mgmt_frame_registrations`/`roamed`/`inform_bss`/`ibss_joined` 等）

### 真机暴露的 4 个运行时 bug（编译期完全看不出）

| # | 问题 | 症状 | 修法 |
|---|---|---|---|
| 1 | `prepare_kernel_cred(NULL)` 在 6.12 警告并返回 NULL，被喂给 `override_creds()` | 空指针崩溃 + **持 rtnl 锁死锁**（`ip addr`/`nmcli`/sshd 全卡） | 改传 `&init_task`，并加 NULL 兜底 |
| 2 | 配置路径 `RT2860AP` vs 运行时硬编码 `RT2870AP` | `rt28xx init fail`，驱动起不来 | 部署到 `/etc/Wireless/RT2870AP/` |
| 3 | `IEEE80211_CHAN_*` 误映射到 `NL80211_RRF_*`（不同枚举，`1<<7` vs `BIT(0)`）；且 `#ifndef` 检测不到枚举常量导致保护失效 | 14 个信道全被判 DISABLED | 只映射内核真删掉的 `PASSIVE_SCAN`/`NO_IBSS` → `IEEE80211_CHAN_NO_IR` |
| 4 | `CachedBuf[16]`（64B）被写入 68B wifi header | `field-spanning write` 警告，静默越界踩坏相邻字段 | 扩到 `[17]`（68B） |

> **教训**：bug #1 和 #3 都是"部分正确"型错误 —— 编译通过、逻辑看似合理，
> 只有真机能暴露。#3 尤其隐蔽：`#ifndef` 对枚举常量永远为真，判重保护形同虚设。

---

## 5. 已部署产物（全部持久化）

```
/lib/modules/6.12.101+deb13-amd64/extra/mt7603u_ap.ko   已修复版
/lib/firmware/mtk/MT7603.bin          e1 固件（64132 B）
/lib/firmware/mtk/MT7603_e2.bin       e2 固件（85944 B）
/etc/Wireless/RT2870AP/RT2870AP.dat   驱动运行时配置
/etc/Wireless/RT2870AP/RT2870APCard.dat
/etc/hostapd/mt7603u.conf             hostapd（WPA2-PSK, ch11）
/etc/dnsmasq.d/mt7603u-ap.conf        DHCP 192.168.50.100-200
/etc/NetworkManager/conf.d/99-unmanage-mt7603u.conf
/etc/modprobe.d/mt7603u.conf          blacklist（挡自动加载，保留显式 modprobe）
```

AP 参数：SSID `MT7603U-AP`，密码 `mt7603u12345`，网关 `192.168.50.1/24`，
NAT 转发至 `wlan0`（内置 Intel 卡）。

---

## 6. 当前启动方式（手动）

```bash
# 1. 加载驱动
insmod /lib/modules/$(uname -r)/extra/mt7603u_ap.ko

# 2. 配置 IP
ip addr add 192.168.50.1/24 dev wlx000000000000
ip link set wlx000000000000 up

# 3. 起 AP 和 DHCP
hostapd -B -P /run/hostapd.mt7603u.pid /etc/hostapd/mt7603u.conf
dnsmasq -C /etc/dnsmasq.d/mt7603u-ap.conf --pid-file=/run/dnsmasq.mt7603u.pid

# 4. NAT
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -A FORWARD -i wlx000000000000 -o wlan0 -j ACCEPT
```

## 7. 待办：固化为开机自动

目前是手动启动。要做成开机自启需要：
1. 移除 `/etc/modprobe.d/mt7603u.conf` 的 blacklist（或改为 udev 触发时显式加载）
2. 写 systemd unit 按依赖顺序拉起：模块 → IP → hostapd → dnsmasq → NAT
3. 若启用 Secure Boot，需对 `.ko` 做 MOK 签名（当前 Secure Boot 已关）

---

## 8. 遗留（不影响使用）

| 项 | 说明 |
|---|---|
| 接口名 `wlx000000000000` | 加载时驱动先用全零 MAC 注册，udev 按那一刻命名。可加 udev 规则按 `b0:d5:9d:xx:xx:xx` 改名 |
| `iw station dump` 为空 | 客户端实际已关联（`Wcid(1)` 在收发数据），仅 station 统计未经 nl80211 导出 |
| `Not support for HIF_MT yet!` | 能力表查询走 `else` 分支的正常噪音，USB 路径本就不支持那些 PCIe 专属功能 |
| MAC 地址 | EFUSE 读出 `b0:d5:9d:xx:xx:xx`，非 Intel 网卡的 `14:85:7f:xx:xx:xx`，无冲突 |

---

# 9. STA 模式（第二阶段）

AP 模式交付后，把同一份源码以 `WIFI_MODE=STA` 编出 `mt7603u_sta.ko` 并实机跑通。

### 编译

STA 路径启用了 `CONFIG_STA_SUPPORT`，暴露出 AP 构建里根本不存在的 4 处内核 API 漂移：

| 报错 | 原因 | 修法 |
|---|---|---|
| `'RTMPCheckEtherType'` 参数 7 类型不符 | 源码漏取地址 | 传 `&wcid` / `&pMacEntry->wcid` |
| `implicit declaration of 'CFG80211_OpsChangeBeacon'/'CFG80211_OpsStopAp'` | 我加的适配器未加条件编译 | 包进 `#ifdef CONFIG_AP_SUPPORT` |
| `cfg80211_scan_done` 传 `bool` 当指针 | ≥4.12 改为收 `struct cfg80211_scan_info *` | `CFG80211OS_ScanEnd` 构造结构体传址 |
| `sme_state`/`CFG80211_SME_*` 不存在、`cfg80211_disconnected` 参数不足 | 4.0 删除 SME 状态机；4.12 增加 `locally_generated` | `rt_6x_compat.h` 第 18 节宏：`RTMP_WDEV_IS_CONNECTING/CONNECTED`、`RTMP_CFG80211_DISCONNECTED(dev, reason, ie, ielen, local)` |

最后一处是 `cfg80211drv.c:1610 CFG80211_LostApInform()`。注意语义：AP 掉线不是本地断开，所以
`locally_generated=FALSE`（而 `cfg80211_inf.c`/`cfg80211_p2p.c` 里由本机发起断开的调用传 `TRUE`）。

结果：`MAKE_EXIT=0`，`RAW_ERRORS=0`。同一棵树再编 `WIFI_MODE=AP` 同样 0 错误，确认 STA 专属改动
没有回归 AP。

### 实机验证

```
wpa_supplicant(nl80211) -> Associated with cc:c2:e0:xx:xx:01 (SSID=OpenWrt, 2412 MHz)
WPA: Key negotiation completed [PTK=CCMP GTK=CCMP]
DHCPOFFER of 192.168.1.132 from 192.168.1.1
iwconfig: Mode:Managed  Frequency=2.412 GHz  Bit Rate=270 Mb/s
iwpriv stat: Last TX Rate = MCS15, 40M, LGI   <- 2SS MCS15 40MHz，速率拉满
             Last RX Rate = MCS15, 40M, SGI
             RSSI = -42/-44, Rx with CRC = 71240 (PER 28.8%), AMPDU Tx PER 14.4%
```

### 吞吐实测（单流 15 s，Windows 对端在 5GHz ch56）

| | HT40 | HT20 |
|---|---|---|
| RX（下载进卡） | 44.3 / 17.2 / 16.7 / 27.8（均值 ~26） | 83.0 / 65.2 / 49.7 / 45.1（均值 ~61） |
| TX（从卡发出） | 47.3 / 26.9 / 46.7 / 44.8（均值 ~41） | 25.3 / 40.0 / 24.1 / 32.7（均值 ~30） |
| 4 流合计 | RX 80.4 / TX 54.0 | RX 102.9 / TX 37.7 |

**默认选 HT20**：RX 两轮都明显更好（与 28.8% 的 RX CRC 错误率吻合——40MHz 在拥挤的 2.4GHz 频段
更容易被打烂），而下载方向更影响体感。HT40 一键可切（见第 11 节）。

> AP 模式能做到 ~200 Mbps，STA 模式只有 ~30–100 Mbps，差距不在驱动而在环境：
> 这是"卡→路由器→5GHz→Windows"两跳转发，且 2.4GHz 频段有多个邻区
> （`campus-wifi` 在 ch11 达 -48 dBm）。频段拥塞是唯一瓶颈。

### 关键运行期发现

1. **NetworkManager 默认打开了省电**：`iw dev get power_save` 报 `on`，RX 从 50 Mbps 掉到 22 Mbps。
   profile 里设 `802-11-wireless.powersave 2`（disable）后恢复。
2. **数据确实走的是这张卡**：用 `ip rule from <sta-ip> lookup 100` 做源地址策略路由，
   再用网卡自身的 `rx_bytes`/`tx_packets` 增量核对（100 MB 载荷对应 ~109 MB 计数）。
   注意驱动**不更新 `tx_bytes`**（一直是几万字节），只能靠 `tx_packets` 判断。

---

# 10. 两次把主机搞挂的教训（重要）

### 事故 A：`prepare_kernel_cred(NULL)` → 空指针崩溃 + RTNL 死锁

见第 4 节 bug #1。表现：内核 oops 时**持有 rtnl 锁**，于是 `ip addr`、`nmcli`、sshd（反查 DNS）
全部永久阻塞，只能硬重启。

### 事故 B：厂商私有 ioctl / 模块卸载路径

测试 20MHz 对比时执行了 `iwpriv <if> stat`（**没加 timeout**），随后主机彻底失联：

- `ping` 通、`TCP/22` 能建连，但 `ssh -v` 卡在 **`Connection timed out during banner exchange`**
  ——内核还活着，但没有进程能再跑起来
- `cat /proc/modules` 也阻塞
- 同时持有 **RTNL**（sshd 会话初始化需要 netdev 信息）和 **module_mutex**（`/proc/modules`），
  指向 **`rmmod mt7603u_sta` 卡在驱动 module-exit 路径**（`rmmod` 会同时拿这两把锁），
  `iwpriv` 也在此前的探测中挂过一次
- 我埋的 `reboot -f` 看门狗**没能救回来**：`reboot -f` 会走 `device_shutdown()`，
  而那个 USB 设备正是卡住的元凶

**规则（已固化为操作纪律）**：

1. **绝不调用 `iwpriv` 等厂商私有 ioctl**。读速率改用 `iwconfig`（标准 wext）或直接读 dmesg。
2. **不要 `rmmod` 这个驱动**。改配置（如 `HT_BW`）只需 NetworkManager 重连——
   `.dat` 每次 netdev open 都会重读，不需要重载模块。
3. 任何可能进驱动 op 的操作之前，先布好**独立于 SSH 会话**的看门狗，且用
   `echo b > /proc/sysrq-trigger`（立即重启，不走 `device_shutdown()`），
   而不是 `reboot -f`。
4. 发现失联要**立刻告知用户**，不要自己连续重试把时间耗掉。

---

# 11. STA 最终配置（全部持久化）

```
/lib/modules/6.12.101+deb13-amd64/extra/mt7603u_sta.ko   已修复版 STA 模块
/etc/modules-load.d/mt7603u-sta.conf     开机自动 modprobe mt7603u_sta
/etc/modprobe.d/mt7603u.conf             blacklist mt7603u_ap（挡住同名 USB 别名的 AP 模块）
/etc/Wireless/RT2870STA/RT2870STA.dat    驱动运行时配置（HT_BW=0 即 20MHz，SSID 留空交给 NM）
/etc/sysctl.d/60-mt7603u-sta.conf        net.ipv4.conf.all.arp_ignore=1
/etc/systemd/system/mt7603u-sta-route.service  源地址策略路由 + 逐网卡 ARP 隔离，enabled
/usr/local/sbin/mt7603u-sta-route.sh     上面这个 unit 的脚本
```

NetworkManager 配置 `mt7603u-sta`（`ifname=wlx000000000000`, ssid=`OpenWrt`）：

```
connection.autoconnect      yes
802-11-wireless.powersave   disable     <- 关键，否则 RX 减半
ipv4.method                 auto
ipv4.never-default          yes         <- 不抢 wlan0 的默认路由
ipv4.route-metric           900
ipv6.method                 disabled
```

策略路由的意义：两张网卡同在 `192.168.1.0/24`，主表里 wlan0（metric 600）必胜，
所以**显式绑定到 STA 地址的流量会悄悄从 Intel 卡出去**。一条 `from <sta-ip> lookup 100`
规则 + 私有表解决，重启由 systemd unit 自动重建。

> 坑：写 `net.ipv4.conf.all.arp_ignore=1` **不会**传播到逐网卡条目（实测 `wlan0` 与 STA
> 都仍为 0），所以真正的隔离必须在 unit 里对 `wlan0` 和 `wlx000000000000` 分别写一次。

切换信道宽度（无需重载模块）：

```bash
sed -i 's/^HT_BW=.*/HT_BW=1/' /etc/Wireless/RT2870STA/RT2870STA.dat   # 1=40MHz, 0=20MHz
nmcli connection down mt7603u-sta && nmcli connection up mt7603u-sta
iwconfig wlx000000000000            # 270=HT40 / 130=HT20
```

---

# 12. 测量工具（`reverse/`）

| 文件 | 用途 |
|---|---|
| `ssh.ps1` | 把任意 bash 脚本经 `bash -s` 灌到 Debian 执行（绕开 PowerShell 引号地狱） |
| `wait-ssh.ps1` | 有界等待主机回来；每次尝试都是带硬超时的子进程，专治"能建连但没 banner" |
| `build_summary.ps1` | 推源码 + 远端编译 + 去重错误摘要（`-WiFiMode AP/STA/APSTA`） |
| `net/netpeer.py` | 定长/定时 TCP 吞吐对端。**监听端始终放 Debian 侧**（绑定 STA 地址），Windows 只做出站连接，因此完全不需要动 Windows 防火墙 |
| `sta-bench-client.ps1` / `sta-bench-repeat.ps1` | 单流/4 流、收发双向测量 |
| `remote/sta-*.sh` | 建 STA、切宽度、关省电、搭测量台、定稿等各步骤脚本 |

> 另一条经验：**测量时要注意方向性偏差**。接收端如果对端卡顿，会把"字节数 ÷ 被拉长的墙钟"
> 算低——曾出现 15 s 窗口实际跑了 23.9 s。结论要以**发送端**的数字为准。

---

# 13. 用正规 iperf3 复测 + 真实网络拓扑（第二阶段收尾）

拿到 `192.168.1.1` 的 root（密码 `<redacted>`，Debian 上已装 `sshpass`）后才发现，
**网络拓扑和我原先的假设完全不同**：

```
campus-wifi (校园网, 5GHz ch48)
      │  STA (phy0-sta0, 74:f0:6d:42:6b:0a)
      ▼
192.168.1.1  ← x86_64 OpenWrt 24.10.2 / Linux 6.6.93
      │        无线配置里**只有**一个 5GHz STA 接口，没有任何 AP！
      │        LAN = br-lan(192.168.1.1/24)，ports='eth1'（靠有线）
      ▼
  局域网 192.168.1.0/24
      │
      ├── 192.168.1.10  debian（Intel 5GHz 客户端）
      ├── 192.168.1.11  windows-pc（Windows，5GHz 客户端）
      └── 192.168.1.12  WR135-5E6A24  ← **真正的 AP**（cc:c2:e0:xx:xx:00）
                 ├── 2.4GHz "OpenWrt"   (cc:c2:e0:xx:xx:01, ch1)  ← MT7603U 连的是这个
                 └── 5GHz   "AP-5G" (cc:c2:e0:xx:xx:02, ch56) ← 其他设备连这个
```

WR135 是 Realtek 方案的低价中继器（Web 服务是 `Boa/0.94.13`，gb2312 编码，
`.asp` 页面），**没有 SSH/telnet，只有 80 端口网页登录**，所以拿不到它的
station dump（它对这张卡的 TX 速率/重传计数）。

好在 iperf3 到 192.168.1.1 是**真正的单跳**（卡 →2.4GHz→ WR135 →有线→ OpenWrt），
比之前"卡→WR135→5GHz→Windows"两跳的测试干净得多。

### 单跳 iperf3 结果（`-B 192.168.1.132`，策略路由保证走卡）

| 方向 | 单流 | 4 流 |
|---|---|---|
| **TX 卡 → 路由器** | 30.8 Mbps | 34.7 Mbps |
| **RX 路由器 → 卡** | **2.94 Mbps**（73 次重传） | 直接 `Connection reset by peer` |

UDP 裸测（15 s）：Windows 发出 **3.13 GB / 1671 Mbps**（灌进黑洞），卡只收到
**3.17 MB（1.6 Mbps，丢包 99.9%）**；反向 TX 仍有 41 Mbps。

**结论：TX 约 31–35 Mbps 可用，RX 只有 2–3 Mbps。** 收/发差 10 倍，
且 UDP 也照样全丢 → 不是 TCP 重传放大出来的假象，是**接收方向真的收不到**。

### 两个待验证的假设

1. **是 WR135 的 2.4GHz 发射烂，还是我们的卡收得烂？**
   注意：同期的 `iwpriv stat` 显示 `Rx with CRC = 71240 (PER 28.8%)` —— 是**我们收错**；
   但更早的 AP 模式实测（卡做 AP、手机做客户端、**ch11**）RX 能到 ~100 Mbps，
   说明卡的接收链本身没问题。→ 需要 A/B：让 Intel 卡也连同一个 2.4GHz AP 比一比。
2. **是不是 ch1 这个频点对这张卡特别差？**
   AP 模式那次在 **ch11** 好好的，现在 STA 在 **ch1**；40MHz 时 RX CRC 28.8%。
   若成立，把 WR135 的 2.4GHz 从 ch1 换到 ch11 即可。

### 附带踩到的坑

**`bash -s` 脚本里再调 `ssh` 会吃掉自己的脚本**：内层 ssh 默认从 stdin 读，
而脚本正是从 stdin 灌进来的，于是第一条命令跑完脚本就"消失"了。
必须给内层 ssh 加 `-n`（或 `</dev/null`）。

---

# 14. 链路 churn 的根因与修复（重要）

在收尾终检时发现一个更严重的问题：**`iw dev link` 报 `Not connected`、网卡 `DORMANT`、
`Bit Rate=1 Mb/s`，但 NM 说已连接、数据还在跑**。顺着 dmesg + NM 日志挖下去：

```
[813] SYNC - End of SCAN, restore to 20MHz channel 1, Total BSS[06]
[815] SYNC - End of SCAN ... → PeerBeaconAtJoinAction()   ← 扫描后重新入网
[828] SYNC - End of SCAN ...
[840] SYNC - End of SCAN ... → PeerBeaconAtJoinAction()
```

NM 日志：
```
device (wlx000000000000): supplicant interface state: disconnected -> scanning
device (wlx000000000000): supplicant interface state: scanning -> associating
device (wlx000000000000): set-hw-addr: failed to set MAC address to 1A:91:FF:EA:4F:98 (scanning)
```
**每 ~12 秒循环一次**。

根因链：这张卡**收信标都不稳** → 驱动连续丢 `BeaconLostTime=4` 个信标就判定 AP 丢失
（`CFG80211_LostApInform`）→ 上报 disconnect → wpa_supplicant 重扫、重连 →
BA 会话与速率自适应每次重建 → 吞吐崩塌（接收方向受害最重）。

**所以 churn 是症状，收不到才是病根。** 两个缓解措施（都已落地）：

| 措施 | 文件 | 效果 |
|---|---|---|
| 关掉 NM 的随机 MAC 扫描（驱动不支持，每次都失败报错） | `/etc/NetworkManager/conf.d/99-mt7603u-wifi.conf`<br>`[device] wifi.scan-rand-mac-address=no` | 消除每轮扫描的失败操作 |
| 放宽丢信标容忍度 `BeaconLostTime` **4 → 30** | `/etc/Wireless/RT2870STA/RT2870STA.dat`（原文件备份为 `.orig`） | **churn 消失**：60 s 内 0 次重新入网 |

修复前后（单跳 iperf3 到 192.168.1.1，5 s）：

| | 修复前 | 修复后 |
|---|---|---|
| TX 卡→路由器 | 23.7 Mbps | **37.7 Mbps** |
| RX 路由器→卡 | 2.94 Mbps | **7.5 Mbps** |
| 60 s 内重新入网次数 | ~5 | **0** |

### 仍未解决：RX 只有 TX 的 1/5

RX 从 3 升到 7.5 Mbps 是缓解，不是治愈。要做完判定，只需二选一：

1. **把 WR135 的 2.4GHz 从 ch1 换到 ch11**（它在 ch11 上被证明过：AP 模式那次 RX 跑到 ~100 Mbps）。
   需要 WR135 的网页登录密码 —— 它只有 HTTP（Boa），没有 SSH/telnet。
2. **A/B 对比**：让 Intel 卡也连到同一个 2.4GHz AP，测同样的 iperf3 收向。
   若 Intel 也只有几 Mbps → 是 WR135 的 2.4GHz 发射问题，我们的移植无责；
   若 Intel 有 25+ Mbps → 是我们的卡接收有问题，需要继续查驱动 RX 路径
   （重点怀疑 `AntCfgInit(2425): Not support for HIF_MT yet!`：天线配置压根没生效）。

---

# 15. A/B/C 对照 —— 结论：瓶颈在 WR135，不在移植（已定论）

按上面的方案 2 做了三重对照。信道一律用 `iw dev <if> info`（nl80211）核实，
不再依赖会误报 `Not-Associated` 的 `iwconfig`。对照期间把 MT7603U 停掉，
避免两张同信道网卡互相抢空口。

| | A) MT7603U @ WR135 2.4G(ch1) | B) Intel MT7925 @ **同一张** WR135 2.4G(ch1) | C) Intel @ WR135 5G(ch56) 基准 |
|---|---|---|---|
| 信道核实 | `freq 2412` ✓ | `channel 1 (2412 MHz)` ✓ | `channel 56 (5280 MHz)` ✓ |
| 20 次 ping | **0% 丢包 / 2.09 ms** | 0% / 2.94 ms | 0% / 1.72 ms |
| TX | **28.4 Mbps** | 7.34 Mbps（对端只收到 3.13） | 134 Mbps |
| RX | **6.28 Mbps** | **测试失败（连接被重置）** | 54.9 Mbps |
| RX 4 流 | 10.4 Mbps | 9.64 Mbps | — |

（更早一轮同样条件下 Intel 在 2.4GHz 是：ping **25% 丢包**、RTT 均值 14 ms / 最大 143 ms、
TX 23.7 / RX 2.96 Mbps —— 方差极大，这本身也说明该 2.4GHz 链路不稳。）

### 结论

1. **我们的卡在同一张 2.4GHz AP 上全面优于 Intel**（TX 28.4 vs 7.3，RX 6.3 vs 跑不出来）。
   一颗驱动极其成熟的 Wi-Fi 7 芯片（MT7925）在同一位置也只有这个水平。
2. **瓶颈是 WR135 本身，且与频段无关**：同一台 WR135 在 5GHz 上，
   Intel 卡 TX 有 134 Mbps 而 **RX 只有 54.9 Mbps** —— 这台便宜中继器
   「AP → 客户端」方向本来就严重瘸腿，2.4GHz 上只是被放大成 6 Mbps。
3. 物理摆放调整后 RX 从 3 → 12.7 Mbps，说明天线位置有影响，但形态未变。

**因此：RX 偏低不是移植缺陷。** 移植质量的上限由这台 WR135 决定；
换一台正经 AP（或把 WR135 的 2.4GHz 换到 ch11、并改善其天线/位置）才能提升。

> ⚠️ **本节结论在第 17 节被修正**：当时我们和 Intel 卡**都装在金属机箱内部**，
> 于是"A/B 显示两张卡都很差"只能证明**环境**差，无法区分是卡还是 AP。
> 真正的元凶是**机箱内部的金属环境**，不是 WR135。

> 顺带：由于我们的模块在开机早期加载、先占用 `wlan0` 又被 udev 改名，
> Intel 网卡现在叫 `wlan1`，而用户原有的 NM 配置 `OpenWrt` 里
> `connection.interface-name` 仍写死 `wlan0`，该配置现已失效（改绑 `wlan1` 或置空即可）。

---

# 16. arm64 / Armbian 移植（内核 6.18.54）—— **编译通过**

用户问"这个驱动能移植到 Armbian 吗"，于是在他局域网里那台 Armbian 上实测。

### 目标机

| 项 | 值 |
|---|---|
| 主机 | 192.168.1.20 |
| 系统 | Armbian OS 26.11.0（Debian 13 trixie） |
| 板子 | `Aml.S905l3b`（Amlogic S905L3B 电视盒子，`meson-gxl`/`amlogic`） |
| 架构 | **aarch64** |
| 内核 | **6.18.54-ophub**（比本机 6.12 还新） |
| 头文件 | `/lib/modules/6.18.54-ophub/build` 已在 |
| 工具链 | gcc 14.2.0（内核是 gcc 15.3 编的，只是警告） |

### 结果

```
MAKE_EXIT=0    原始 error 计数 = 0    log 10391 行
产物: mt7603u_sta.ko  58 MB
file: ELF 64-bit LSB relocatable, ARM aarch64
modinfo vermagic: 6.18.54-ophub SMP preempt mod_unload aarch64
```

**同一份源码在两端都 0 错误**：x86_64 + 6.12.101（回归通过）与 aarch64 + 6.18.54。

### 为此新增的 6 处适配（全部版本门控，`rt_6x_compat.h` 第 19 节）

| # | 内核变化 | 症状 | 修法 |
|---|---|---|---|
| 1 | **6.15 彻底删除 `EXTRA_CFLAGS`** | 厂商把**所有** `-I/-D` 都塞在 `EXTRA_CFLAGS` 里，一旦被忽略就**静默全丢** → `fatal error: rt_config.h: No such file or directory`（kbuild 不会报"EXTRA_CFLAGS 不支持"） | `config.mk` 末尾加 `ccflags-y += $(WFLAGS) -I$(RT28xx_DIR)/include`（老的保留，重复的 `-I/-D` 无害） |
| 2 | 6.13 大多数 `cfg80211_ops` 回调改收 `struct wireless_dev *` | 9 处 incompatible-pointer-type | 宏 `RTMP_CFG80211_WDEV_ARG` / `RTMP_CFG80211_NDEV_OF()`，包装函数里用 `(wdev)->netdev` |
| 3 | 6.14 `set_wiphy_params` 新增 `int radio_idx` | 同上 | 新增 `_Compat` 包装吞掉该参数 |
| 4 | 6.14 `remain_on_channel` 新增 `const u8 *rx_addr` 且 cookie 改为按值；`mgmt_tx` cookie 也改按值 | 同上 | 新增包装，cookie 经本地变量转交 |
| 5 | 6.13 `cfg80211_new_sta` / `cfg80211_del_sta` 同样改收 wdev | 2 处 | `RTMP_CFG80211_STA_WDEV()`（走 `netdev->ieee80211_ptr`） |
| 6 | 6.15 `del_timer_sync()` 改名 `timer_delete_sync()` | `implicit declaration` | `RTMP_DEL_TIMER_SYNC()` |

> **关键坑：并非所有回调都改了。** `change_virtual_intf`、`change_beacon`、`stop_ap`、
> `set_default_key`、`set_power_mgmt`（以及 `add_mpath`、`set_cqm_*`）在 6.18 里
> **仍然收 `net_device *`**。这是一一对照 6.18 自带的 `include/net/cfg80211.h` 得出的，
> 不能"顺手全改"——改错反而编不过。
> 同理，`cfg80211_ops` 的签名不能凭记忆猜：**直接从目标内核的头文件里抽**
> （`awk '/^struct cfg80211_ops \{/,/^\};/'`）是最省时间的做法。

### 附带修掉一个与内核版本无关的构建缺陷

Armbian 上第一次失败在日志**第 25 行**，看着像内核问题，其实是 `make -j4` 的竞态：

```
make: *** [Makefile:481: plug_in] Error 2
  MODPOST Module.symvers
  /root/.../os/linux/Module.symvers: No such file or directory
```

`all: build_tools $(TARGET) plug_in` 让 `LINUX` 与 `plug_in` **并发**执行，而
`tools/plug_in/Makefile` 通过 `KBUILD_EXTRA_SYMBOLS` 依赖 `os/linux/Module.symvers`，
那时它还没生成。Debian 上我一直没加 `-j` 所以从未暴露。已在 `Makefile` 里补上真实依赖：

```make
plug_in: $(TARGET)
```

### Armbian 上已铺好的运行时环境（插卡即可用）

```
/lib/modules/6.18.54-ophub/extra/mt7603u_sta.ko   59.9 MB
/etc/modules-load.d/mt7603u-sta.conf              开机自动加载
/lib/firmware/mtk/MT7603.bin, MT7603_e2.bin       与 x86 侧同一份（芯片固件，与架构无关）
/etc/Wireless/RT2870STA/RT2870STA.dat             HT_BW=0, BeaconLostTime=30, CN
NetworkManager 配置 mt7603u-sta                    autoconnect + powersave disable + never-default
```

空载试装（机器上还没插那张卡）：
```
modprobe mt7603u_sta  -> rtusb init mt_drv ---> / usbcore: registered new interface driver mt_drv
rmmod mt7603u_sta     -> 干净卸载（没有 USB 设备绑定，不会触发之前那个 module-exit 卡死）
```

**尚未做的**：arm64 上的**运行**验证。360 卡目前仍插在 Debian 那台机器上；
把它插到 Armbian 盒子上就会自动绑定并按上面的 NM 配置去关联 `OpenWrt`。

### 回答用户的问题

**可以。** 而且不是"理论上可以"——是**已经编出来了**：
aarch64 + 6.18.54 的 `mt7603u_sta.ko` 就在那台机器上，两端回归都过。
唯一保留意见：6.13 / 6.14 这两个门控边界是**尽力而为**
（只实测了 6.12 与 6.18），而且 arm64 上还没做运行验证。

---

# 17. RX 的真正病根：金属机箱（**更正第 15 节**）

第 15 节把 RX 只有 6–13 Mbps 归因于"WR135 中继器下行弱"。**那个结论是错的。**

用户随后做了两件事：

1. 把 AP 从 **ch1 换到 ch11**；
2. **加了一根 USB 延长线，把网卡移出金属机箱**——这台机器是金属外壳，
   卡原本插在机箱内部，USB 口附近也全是金属。

同样的 WR135、同样的 iperf3 服务器（192.168.1.1）、同样是单跳：

| 方向 | 改动前 | **改动后** |
|---|---|---|
| RX 单流 | 2.9 / 5.7 / 6.3 / 7.5 / 12.7 Mbps | **91.0 / 94.2 / 52.2 Mbps** |
| RX 4 流 | 8.6 / 10.4 Mbps | **96.1 Mbps** |
| TX 单流 | 23.7 – 37.7 Mbps | 27.6 – 36.2 Mbps |
| TX 4 流 | 31 – 34.7 Mbps | 43.2 Mbps |
| ping | 0% 丢包 / 2.0 ms | 0% 丢包 / **1.9 ms** |

**RX 提升约 7 倍，而 TX 几乎没变** —— 这正是指向"天线被金属包裹"的特征：
发送端有 ~20 dBm 的功率硬顶，接收端损失的是**灵敏度**，所以收比发敏感得多。

### 方法论教训（重要）

第 15 节的 A/B 对照里，**我们的卡和 Intel 卡都装在同一个金属机箱内部**，
共享了同一个环境因素。因此"两张卡都很差"只能推出**环境差**，
**不能**推出"WR135 有责任"。要分离"网卡"与"AP"，
必须至少让其中一个变量离开共享环境——我当时跳过了这一步。

### 当前健康状态

RX 约为 TX 的 2.5 倍，多次采样稳定在 50–94 Mbps（链路 2×2 MCS15 / HT20 / ch11）。
这是这张卡在这套环境下的正常水平，与移植质量无关。

---

# 18. arm64 运行时验证 —— **成功**（并修掉两个只有 arm64 才暴露的 bug）

把卡插到 Armbian 盒子后，编译通过并不等于能跑：**probe 连续失败了两次**，
而且这两次失败在 x86_64 上永远不会出现。修完后 arm64 上**完全跑通**。

### 两个 arm64 专属运行时 bug

#### bug 1：`GFP_ATOMIC` 的 coherent 分配撞上原子 DMA 池（256 KB）

```
DMA pool exhausted for c9000000.usb
WARNING: CPU: 3 PID: 33488 at kernel/dma/pool.c:282 dma_alloc_from_pool
  usb_alloc_coherent ← RTMPAllocUsbBulkBufStruct ← RTMPAllocTxRxRingMemory
<-- ERROR in Alloc Bulk buffer for HTTxContext!
Failed to allocate memory - TxRxRing
mt_drv 1-2:1.0: probe with driver mt_drv failed with error -1
```

驱动用 `usb_alloc_coherent(dev, size, GFP_ATOMIC, ...)` 申请约 1 MB 的 bulk 缓冲。
x86_64 上 `dma_direct_alloc()` 能直接走 `alloc_pages`；而 Meson SoC 的 USB 控制器
只有 32 位 DMA 能力，**非阻塞**的 coherent 分配会被路由到每设备的原子 DMA 池
（默认几百 KB）→ 池子爆掉 → probe 失败。
`RTUSB_URB_ALLOC_BUFFER` 的所有调用点都在 probe / 固件上传的进程上下文里，
本来就是可以睡眠的，所以正解就是改用 `GFP_KERNEL`：

```c
/* rt_6x_compat.h 第 20 节；x86_64 保持 GFP_ATOMIC 不动 */
#if defined(CONFIG_ARM64) || defined(CONFIG_ARM)
#  define RTMP_USB_COHERENT_GFP   GFP_KERNEL
#else
#  define RTMP_USB_COHERENT_GFP   GFP_ATOMIC
#endif
```

#### bug 2：`os_alloc_mem()` 是裸 `kmalloc()`，band 结构体带堆垃圾进 `wiphy_register`

```
Segmentation fault  (modprobe)
wiphy_register+0x47c/0x9c0 [cfg80211]
CFG80211_Register+0x1b0/0x35c [mt7603u_sta]
rt2870_probe+0x214/0x480
Code: ... (79400020)     ← ldrh w0, [x1]
x1 : ffffffff00000080    ← 野指针
```

`os_alloc_mem()` 实现是 `kmalloc(size, GFP_ATOMIC)` —— **不清零**。
驱动的 `pCfg80211_CB->Cfg80211_bands[]`（`struct ieee80211_supported_band`）就落在这块
未清零的堆上，而驱动只填它认识的字段。6.18 在该结构体末尾新增了
`u16 n_iftype_data` 和 `const struct ieee80211_sband_iftype_data __iftd *iftype_data`，
`wiphy_register()` 会遍历 `iftype_data[i]`，其中 `types_mask` 正是 **u16**
—— 于是 `ldrh w0, [x1]` 从垃圾指针取值，段错误。

修法：分配后清整个 CB，并在填每个 band 前清零该 band 结构体。
这本来就是卫生问题（内核结构体不能带未初始化字段交回去），只是 x86_64 恰好没踩到。

### arm64 运行结果（192.168.1.21）

| 指标 | 值 |
|---|---|
| 接口 / MAC | `wlan0` / `b0:d5:9d:xx:xx:xx` |
| 关联 | `OpenWrt`，ch11 (2462 MHz)，`Bit Rate=130 Mb/s`（2×2 MCS15 HT20） |
| 省电 | `off` |
| ping（20 次） | **0% 丢包**，均值 4.6 ms |
| **TX** | **33.8 / 32.1 / 35.5 Mbps** |
| **RX** | **111 / 110 / 111 Mbps** |
| 4 流 | TX 30.5 / RX 97.8 Mbps |

**开机即用**：这台盒子不用 NetworkManager 管 Wi-Fi，而是
`/sbin/wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf`（里面配的就是 `OpenWrt`），
我们模块由 `modules-load.d` 在启动早期加载并先占住 `wlan0`，于是 wpa_supplicant 直接
把它驱动起来了。它自带的 RT5372（老 `wlan0`）反而没起来 —— 用户说那张卡本来就不稳定。

> 命名注意：Armbian 用的是经典命名（`net.ifnames=0`），所以我们的卡是 `wlan0`、
> RT5372 是 `wlan1`；而 Debian 那台是 `wlx000000000000`。因为
> `wpa_supplicant` 是按名字 `-i wlan0` 绑定的，**如果哪天 RT5372 先枚举**，
> 就会配错卡。目前我们的模块由 `modules-load.d` 在早期确定性加载，所以稳定占住 `wlan0`。

### 我在这一节里犯的两个错（记下来）

1. **ping 错地址就下结论**：Armbian 重启后拿到的是新地址 `192.168.1.21`（我们的卡），
   我却在 `192.168.1.20`（它那张失效的 RT5372）上连续探测了 9 分钟，然后
   错误地推断"关机卡在 `rtusb_disconnect`、机器已挂"。实际上机器好好的，
   **我这条 SSH 当时就能通过新卡连上去**。教训：地址不可达时，先看 DHCP 租约/新 MAC，
   而不是反复 ping 一个可能已经过期的地址。
2. **重启了一台我够不到的机器**：为了装新模块我直接 `systemctl reboot`，
   而这台盒子我无法物理接触。虽然这次它正常回来了（重启本身没问题），
   但做法本身是错的 —— 对够不到的机器应该优先用 `rmmod`/`modprobe` 就地换模块，
   或者先确认有可靠的带外恢复手段。
