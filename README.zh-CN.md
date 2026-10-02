# CloseWRT-CI

[English](README.md) | 简体中文

编译 Padavanonly 的 ImmortalWRT 固件

PADAVANONLY-24.10
https://github.com/padavanonly/immortalwrt-mt798x-24.10.git

# 说明：

本项目仅支持编译包含 defconfig 目录的闭源 MTK SDK 项目。

# 固件概览：

固件在每周二悉尼时间凌晨 3 点自动编译。

固件信息中显示的时间是编译开始的时间，可用于核对上游源码的提交时间。

本固件兼容官方主线 OpenWRT 的 U-Boot，刷机请按其说明操作。

# 目录说明：

workflows — 自定义 CI 配置

Scripts — 自定义脚本

Config — 自定义配置

Files — 打包进固件根文件系统的文件（由 Settings.sh 复制到 `./files`）

# 已知问题与特殊之处：

本固件基于 padavanonly 的源码。padavanonly fork 了 ImmortalWRT 并加入了 MTK 闭源驱动，因此它既继承了 ImmortalWRT 的所有特性和问题，也带有 padavanonly 自己的特性和问题。

## 国家代码 / 5GHz 信道限制修复

上游源码中有三个叠加的 bug，导致即使在 LuCI 中把国家代码改为 AU（或其他国家），路由器仍被锁定在中国（CN）的监管设置上。本固件打了补丁，三个问题都已修复。

**Bug 1 — AU 的 5GHz 区域映射错误**

`mtwifi_defs.lua` 把澳大利亚映射到 5GHz Region 0，该区域只包含 36–64 和 149–165 信道，缺少澳大利亚合法可用的 DFS 信道 100–140。本固件把 AU 改为 Region 7，覆盖完整的澳大利亚信道规划：
- 36–64（UNII-1 + UNII-2A）
- 100–140（UNII-2C，DFS）
- 149–165（UNII-3）

**Bug 2 — 硬件 eFuse 覆盖软件设置的国家代码**

MTK 闭源驱动在初始化时调用 `Config_Effuse_Country()`，从路由器出厂 flash 分区读取 CN 国家代码，并覆盖你在 dat 文件或 LuCI 中设置的国家。它还会设置一个锁定标志（`EEPROM_IS_PROGRAMMED`），在接口启用期间静默拒绝之后通过 `iwpriv` 修改国家代码。这就是为什么无论 LuCI 怎么设置，驱动层的国家代码看起来都锁定为 CN。本固件注释掉了这个调用，国家代码完全由软件（UCI/LuCI）控制。

**Bug 3 — 首次启动时默认国家为 CN**

`mtwifi.sh` 在首次检测到无线接口时把 `country=CN` 写为 UCI 默认值。本固件把默认值改为 AU。

## AdguardHome

设置 AdguardHome 时需要注意：

1. 需要 SSH 登录路由器，编辑 `/etc/config/adguardhome`，把 enabled 一行改为：
    `option enabled '1'`
    OpenWRT 没有这个问题，ImmortalWRT 有（来源：https://github.com/immortalwrt/packages/blob/master/net/adguardhome/files/adguardhome.config）

2. dnsmasq 中有一段 Padavanonly 内置的脚本（来源：https://github.com/padavanonly/immortalwrt-mt798x-6.6/blob/2806544a5a38283c6e778fa0a91e955e27e9987e/package/network/services/dnsmasq/files/dnsmasq.init#L1278）
```
	if [ "$dns_redirect" = 1 ]; then
		nft add table inet dnsmasq
		nft add chain inet dnsmasq prerouting "{ type nat hook prerouting priority -95; policy accept; }"
		nft add rule inet dnsmasq prerouting "meta nfproto { ipv4, ipv6 } udp dport 53 counter redirect to :$dns_port comment \"DNSMASQ HIJACK\""
	fi
```
解决方法如下：
```
#turn off the dns_redirect
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp

#delete the nft firewall rule
nft delete table inet dnsmasq

#restart dnsmasq
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
```

## IoT / 智能家居设备（涂鸦/Smart-Life、德业/Solarman 等）

一些廉价的 IoT Wi-Fi 模块（基于 ESP/lwIP 的涂鸦/Smart-Life、德业/Solarman 光伏采集器等）在本固件上表现异常：能正常连上 AP，但上线或连接云端很慢、很不稳定——而连接手机热点或"傻瓜式"中继器时却很快。以下是一个真实家庭的经验记录，并不是严谨的拆解分析——**下面的修复方法是我们实测有效的**；部分**根因解释只是尽力推测**，会特别标注。这些内容都不是 MTK SDK 特有的——DNS 相关部分同样适用于原版 OpenWrt + AdGuard Home。

> **术语说明——请先阅读。** 下面所有示例中，**`iot` 是我们专门为智能家居设备创建的防火墙区域 / 网络的名字**（子网 `192.168.5.0/24`，路由器 IP `192.168.5.1`，Wi-Fi VAP `<iot-vap>`）。这些名字**只属于我们的环境**。凡是看到 `iot`、`192.168.5.x` 或 `<iot-vap>` 的地方，请替换成**你自己的**区域名 / 子网 / 接口。并非一定要有单独的 IoT 网络，但有了它，下面按子网设置的 DNS 规则才能保持干净、不影响主局域网。

### 1. 设备把 DNS 发往过期的/外部的解析服务器（涂鸦，例如 Kogan 空调）
我们发现一台涂鸦空调一直在向一个不属于本网络的 DNS 服务器发查询——看起来是它上次配网时所用手机热点留下的地址（运营商 CGNAT 的 `10.x`）。在路由器上这些查询得不到回应，于是它无法解析涂鸦云端的域名。可以这样检查：
```
cat /proc/net/nf_conntrack | grep <device-ip>   # e.g. dst=10.x.x.x dport=53 [UNREPLIED]
```
我们不知道设备会坚持使用这个过期解析服务器多久——很可能等某个内部缓存/租约过期后它会自己恢复，只是我们没有耐心等。不管怎样，可靠的修复方法是**把所有 IoT 的 DNS 重定向到本地解析服务器**，这样设备想用哪个服务器都无所谓：
```
uci add firewall redirect
uci set firewall.@redirect[-1].name='Force-IoT-DNS'
uci set firewall.@redirect[-1].src='iot'                 # your IoT zone
uci set firewall.@redirect[-1].proto='tcp udp'
uci set firewall.@redirect[-1].src_dport='53'
uci set firewall.@redirect[-1].dest_ip='192.168.5.1'     # this router's IoT-side IP (the DNS server)
uci set firewall.@redirect[-1].dest_port='53'
uci set firewall.@redirect[-1].target='DNAT'
uci set firewall.@redirect[-1].family='ipv4'
uci commit firewall && /etc/init.d/firewall reload
```
这样设置后，设备立刻上线，不用再等。

### 2. WAN 没有 IPv6 时 AdGuard Home 返回 IPv6 AAAA 记录（同样适用于原版 OpenWrt）
如果你的 WAN **没有可用的 IPv6**（`ifstatus wan6` → `"up": false`），但局域网仍在发送 IPv6 RA，支持 IPv6 的 IoT 设备可能会**优先通过 IPv6** 连接云端，并因为没有出口路由而卡住。除非你明确设置，AdGuard Home 不会过滤 AAAA（IPv6）记录，于是设备不断拿到它会优先使用的 IPv6 地址。在这种状态下，我们观察到一台涂鸦设备"短暂连上后又掉线"，并大致周期性地自行断开；而它在只分配 IPv4 的手机热点上工作正常。我们不能断言 IPv6 是唯一原因，但把 IoT 设备的 DNS 引导到 IPv4 后问题就解决了，而且这样做风险很低，值得一试。

有两种方式让 IoT 设备通过 IPv4 访问云端：
- **粗暴（全网）：** 在 AdGuard Home 中关闭 IPv6 解析——*设置 → DNS 设置 →"禁用 IPv6 地址解析"*（`aaaa_disabled: true`）。简单，但会让**所有**客户端都拿不到 AAAA 记录。
- **精准（我们的做法）：** 让 AdGuard **只对 IoT 子网**返回空的 AAAA 应答（NODATA），主局域网保留完整的 IPv6。IPv6 RA 保持开启（设备仍会获得地址），只是解析不到云端的 AAAA 记录。在 AdGuard Home → *过滤器 → 自定义过滤规则* 中添加（换成你的 IoT 子网）：
```
/.*/$client=192.168.5.0/24,dnstype=AAAA,dnsrewrite=NOERROR
```
验证（从 IoT 子网发起查询）：
```
nslookup -type=AAAA a1.tuyaeu.com 192.168.5.1   # empty answer (blocked)
nslookup -type=A    a1.tuyaeu.com 192.168.5.1   # returns IPv4  (works)
```
> 要手动编辑 `/etc/adguardhome.yaml`？**先停止 AdGuard**（`service adguardhome stop`）——它在退出时会重写该文件，覆盖你的修改。把规则加在 `user_rules:` 下，然后再启动。

### 3. 没有 IPv6 RA 就无法工作的采集器（德业/Solarman）——机制不明
与直觉相反，我们的德业光伏采集器表现得和涂鸦设备**正好相反**。在 IoT 网络完全禁用 IPv6 时，它能连上并获得 DHCP 租约，但之后**完全沉默**（没有 DNS，没有任何流量——`tcpdump -i <iot-if>` 什么都抓不到）。在该网络上重新开启 IPv6 RA/SLAAC 并让它重新连接后，它立刻连回了云端。

我们确实**没有经过确认的解释**，而且还有一个始终没解开的矛盾：同一台采集器在完全没有 IPv6 的**纯 IPv4 中继器**上工作得很好，但在这台路由器上，只有存在 IPv6 RA 时才能工作。所以"这台设备需要 IPv6"这个结论太过绝对——请把它当作只针对我们环境的观察。如果你有支持 IPv6 的采集器工作异常，值得试试把 RA **打开**（配合第 2 条中的 AAAA 屏蔽，可以保护只用 IPv4 的设备）：
```
# IoT network: advertise RA/SLAAC but stay ULA-only (no global prefix needed)
uci set network.iot.ip6assign='64'
uci set network.iot.delegate='0'
uci set dhcp.iot.ra='server'
uci commit network; uci commit dhcp
/etc/init.d/network reload; /etc/init.d/odhcpd restart
```

### IoT 杂项笔记
- 首次**涂鸦配网**有时直接连路由器 SSID 会失败；先让设备与手机热点（相同 SSID/密码）配网，再关闭热点，可作为一次性的变通办法。
- 不碰设备本身、让卡住的设备干净地重新连接（mtwifi）：
  `iwpriv <iot-vap> set DisConnectSta=<MAC>`。
- 为挑剔的廉价芯片准备的、对 IoT VAP 无害的"舒适"设置（按 VAP 设置，不影响主射频）：在 IoT 的 `wifi-iface` 上关闭 `ieee80211k`、`ieee80211r`、`ofdma_dl/ul`、`mumimo_dl/ul`、`amsdu`。对我们来说这些单独都没能解决问题，但也没有坏处。

## 手机 USB 网络共享作为备用 WAN（NBN 优先的故障切换）

固件中已包含所需的一切：把手机插到路由器的 USB 口，就能把手机的网络共享用作**备用** WAN：

| 软件包 | 用途 |
|---|---|
| `kmod-usb-net-rndis`、`kmod-usb-net-cdc-ether` | 安卓 USB 网络共享（RNDIS，大多数手机） |
| `kmod-usb-net-cdc-ncm` | 使用 NCM 而非 RNDIS 的安卓手机的 USB 网络共享 |
| `kmod-usb-net-ipheth`、`usbmuxd` | iPhone USB 网络共享（个人热点）。usbmuxd 负责"信任此电脑"配对；配对记录保存在 `/etc/lockdown`，sysupgrade 后保留 |
| `mwan3`、`luci-app-mwan3`、`ip-full` | 对每条 WAN 做健康检查，并完成故障切换 / 回切。状态页面：**状态 → MultiWAN Manager** |

在本固件上**无法**之后再用 `opkg` 添加内核模块：MTK SDK 内核的结构体布局与官方 ImmortalWrt 构建不同（`6.6.x` vermagic 相同，但字段偏移不同），官方内核模块能加载，但随后会破坏内存。所有内核相关的东西都必须在这里编译。

`Files/` 会在编译时复制进固件根文件系统。`Files/etc/hotplug.d/net/05-tether-rename` 会给网络共享网卡改名，让 MTK HNAT 不去接管它们（见下方"踩坑记录"）。`Files/etc/uci-defaults/99-mwan3-stock-off` 会在全新刷机后、mwan3 配置仍是软件包自带示例时禁用 mwan3（该示例默认的 `last_resort` 会在健康检查失败时让所有流量不可达）。sysupgrade 保留下来的真实 mwan3 配置不受影响。

### 实际行为

完成下面的路由器端配置后：

- **正常情况：** 所有流量走主 WAN（`eth1` 上的 NBN）。插在 USB 口、开着网络共享的手机只是一条待命链路：路由器大约每分钟通过它 ping 一次（每天约 0.5 MB 移动数据），除此之外不经过它发送任何流量。
- **故障切换：** 当主 WAN **约 20 秒没有互联网**时，流量切换到手机。无论是网线被拔、NBN 断网，还是 WAN 没拿到 DHCP 地址，都一样。路由器的判断依据是*通过 WAN 口本身* ping 1.1.1.1、8.8.8.8、9.9.9.9，而不是看链路状态。如果此时没有手机在共享网络，那就没有互联网。
- **回切：** 使用手机期间，主 WAN 仍在后台持续检测。**连续约 60 秒检测正常**后，流量切回主 WAN，**即使手机仍然插着、仍在共享网络**，以节省移动数据。
- **每次切换都会重置现有连接**，让它们在新线路上重新建立，而不是卡住。视频通话、下载会中断一下。
- **哪些网络可以用手机上网**，由转发到 `tether` 区域的防火墙转发规则决定。在我们的配置里，`lan` 和 `iot` 可以；`lan2` 不可以，所以使用手机时 lan2 就没有互联网。
- **IPv6** 只能通过主 WAN 获得。使用手机时，`wan6` 会被关闭，路由器也不再通告 IPv6 默认路由，局域网设备会回退到 IPv4。回切后 IPv6 恢复。
- **DNS 不受影响：** AdGuard Home 的上游是公共解析服务器（到 1.1.1.1 的 DNS-over-TLS），通过手机同样可以访问。
- **使用手机时，入站连接全部失效。** 端口转发、从外面连回家的 WireGuard 客户端和 DDNS 都会受影响，因为移动数据位于运营商级 NAT 之后。如果由*路由器*主动连接一台有公网 IP 的服务器并开启 keepalive，这条隧道可以保持；见下方 WireGuard 相关的坑。
- **手机显示为 `tether0`，iPhone 显示为 `iphone0`，而不是 `usb0`/`eth2`。** `05-tether-rename` 会在插入的瞬间给它们改名，因为否则 MTK 硬件 NAT 会劫持手机的 TCP/UDP 流量（见下方 HNAT 相关的坑）。插上手机后，可能要 **30–60 秒** MultiWAN 页面才会显示手机链路在线。如果主 WAN 已经完全断开，这段时间里流量其实已经在走手机了。
- **查看状态：** LuCI → **状态 → MultiWAN Manager** 会显示每条链路是否在线，以及当前由哪条承载流量（例如 `wan (100%)` 或 `usbwan (100%)`）。

### 路由器端配置（不包含在固件中）

相关行为由 `/etc/config/{network,firewall,mwan3}` 和 `/etc/mwan3.user` 决定，它们在 sysupgrade 后都会保留。全新刷机后需要重新创建：

- **network**：安卓用 `usbwan`（proto `dhcp`，device `tether0`，metric `20`），iPhone 用 `iphonewan`（proto `dhcp`，device `iphone0`，metric `30`）。这两个名字来自 `Files/etc/hotplug.d/net/05-tether-rename`（见下方 HNAT 相关的坑）；没有它，内核会把它们命名为 `usb0` 和 `eth2`。
- **firewall**：单独的 `tether` 区域（网络 `usbwan iphonewan`，input/forward 为 `REJECT`，开启 `masq` + `mtu_fix`），并从允许使用移动数据的区域（例如 `lan`、`iot`）添加转发。没有转发到 `tether` 的区域（例如 `lan2`）在使用手机时自然就没有互联网——不需要额外规则。为 `tether` 添加一条 `Allow-DHCP-Renew` 规则（udp/68）。
- **mwan3**：一个策略，`wan` 成员 metric 1，`usbwan`/`iphonewan` 成员 metric 2，`last_resort default`（回退到主路由表，而不是丢弃流量），再加一条使用该策略的 IPv4 规则。`wan` 每 5 秒用多个公网 IP 检测（`down 4` ≈ 20 秒切换，`up 12` ≈ 连续 60 秒正常后回切），并设置 `flush_conntrack connected disconnected`；手机链路检测得慢一些（`interval 60`），以节省移动数据。
- **`/etc/mwan3.user`**（可选）：在 `wan` `disconnected` 时关闭 `wan6`，`connected` 时再打开（用 `ubus call network.interface.wan6 up/down`，不要用 `ifup`，它会把已经启用的接口重启一遍），让使用手机期间局域网设备放弃 NBN 的 IPv6 前缀。

搭建过程中踩过的坑：

- **不改名的话，MTK HNAT 会让 USB 网络共享失效。** HNAT 会把名字以设备树中 `ext-devices-prefix` 开头的任何设备（MT7986 上是 `usb`、`wwan`、`rmnet`、`eth2`、`eth3`、`eth4`）当作"外部设备"接管，把它收到的 TCP/UDP 送进 PPE 绕一圈，并打上 12 位的 VLAN ID 标签 `ifindex & 0xFFF`。回来时它按 `ifindex == vlan` 查找设备，一旦 ifindex 超过 4095（长时间运行、反复插拔、VPN 重启都会让它增大），就永远匹配不上——回包会被发到局域网网桥上。症状：通过手机 ICMP 正常（HNAT 不处理），但 DNS/TCP 静默失败。`05-tether-rename` 会在热插拔 `add` 事件、netifd 启用网卡之前，把 `rndis_host`/`cdc_ether`/`cdc_ncm` 网卡改名为 `tether0`，把 `ipheth` 改名为 `iphone0`，这样 HNAT 永远不会接管它们，由 CPU 像普通接口一样转发。注意 `cdc_ether` 也驱动很多 USB 以太网转接器，它们同样会被改名为 `tether0`。
- netifd 按顺序逐个处理接口热插拔事件，而每次 `ifup`/`ifdown` 都会触发防火墙重载等钩子，所以手机链路接入后，mwan3 可能要 30-60 秒才把它标记为在线。如果此时 NBN 已断开，流量会先通过主路由表中的默认路由（metric 20）走手机。
- 安装时：`opkg install mwan3` 会立即用自带示例配置启用并启动它。手动安装时请用 `IPKG_NO_SCRIPT=1 opkg install …`，配置好后再自己启动。
- 设置了 `endpoint_host` 的 WireGuard 对端，会在 `ifup` 时经由当时的 WAN 固定一条主机路由，这条路由会绕过 mwan3——隧道会一直留在已经断开的 NBN 上。请在 WireGuard 接口上设置 `option nohostroute '1'`（除非隧道承载默认路由，否则是安全的）。
- `/etc/init.d/network reload` 不会应用 WireGuard *对端（peer）* 配置段的修改；需要运行 `ifup <wg-interface>`。
- 手机通常每次重新插拔后都要重新打开 USB 网络共享；安卓的开发者选项 *默认 USB 配置 → USB 网络共享* 可以让它自动开启。路由器的 USB 口约提供 0.9 A 电流，所以大量使用网络共享时可能只是减缓耗电，而不是充电。
