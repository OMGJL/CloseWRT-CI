# CloseWRT-CI

English | [简体中文](README.zh-CN.md)

Compile Padavanonly's ImmortalWRT Firmware

PADAVANONLY-24.10
https://github.com/padavanonly/immortalwrt-mt798x-24.10.git

# Note:

This project only supports compiling closed-source MTK SDK projects that contain a defconfig directory.

# Firmware Overview:

The firmware is automatically compiled at 3 AM Sydney time every Tuesday.

The time shown in the firmware information is the build start time, which helps verify the upstream source code commit time.

The official mainline OpenWRT U-Boot is compatible with this firmware. Please follow their flashing instructions.

# Directory Overview:

workflows — Custom CI configurations

Scripts — Custom scripts

Config — Custom configurations

Files — Files baked into the firmware rootfs (copied to `./files` by Settings.sh)

# Quirks:

This firmware is built by padavanonly, who forked ImmortalWRT and added the MTK closed-source driver. As a result, it has inherited all of ImmortalWRT's quirks as well as padavanonly's own quirks.

## Country Code / 5GHz Channel Restriction Fix

The upstream source has three layered bugs that lock the router to China (CN) regulatory settings, even after changing the country code to AU (or any other country) in LuCI. This build applies patches to fix all three.

**Bug 1 — Wrong 5GHz region mapping for AU**

`mtwifi_defs.lua` maps Australia to 5GHz Region 0, which only covers channels 36–64 and 149–165. DFS channels 100–140, which are legally permitted in Australia, are missing. This build changes AU to Region 7, which covers the full Australian channel plan:
- 36–64 (UNII-1 + UNII-2A)
- 100–140 (UNII-2C, DFS)
- 149–165 (UNII-3)

**Bug 2 — Hardware eFuse overrides software country code**

The MTK closed-source driver calls `Config_Effuse_Country()` during initialisation, which reads the CN country code from the router's factory flash partition and overwrites whatever country you set in the dat file or LuCI. It also sets a lock flag (`EEPROM_IS_PROGRAMMED`) that silently rejects any subsequent country change via `iwpriv` while the interface is up. This is why the country code appeared locked to CN at the driver level regardless of LuCI settings. This build comments out that call so the country code is fully controlled by software (UCI/LuCI).

**Bug 3 — Default country is CN on first boot**

`mtwifi.sh` writes `country=CN` as the UCI default when wireless interfaces are first detected. This build changes the default to AU.

## AdguardHome

Specifically, for setting up AdguardHome:

1. You'll need to SSH into the router, edit `/etc/config/adguardhome`, and modify the enabled line to:
    `option enabled '1'`
    This quirk is not present in OpenWRT but is in ImmortalWRT (source: https://github.com/immortalwrt/packages/blob/master/net/adguardhome/files/adguardhome.config)

2. On dnsmasq, there's a built-in script from Padavanonly (source: https://github.com/padavanonly/immortalwrt-mt798x-6.6/blob/2806544a5a38283c6e778fa0a91e955e27e9987e/package/network/services/dnsmasq/files/dnsmasq.init#L1278)
```
	if [ "$dns_redirect" = 1 ]; then
		nft add table inet dnsmasq
		nft add chain inet dnsmasq prerouting "{ type nat hook prerouting priority -95; policy accept; }"
		nft add rule inet dnsmasq prerouting "meta nfproto { ipv4, ipv6 } udp dport 53 counter redirect to :$dns_port comment \"DNSMASQ HIJACK\""
	fi
```
The way to work around this is:
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

## IoT / Smart-Home Devices (Tuya/Smart-Life, Deye/Solarman, etc.)

Some cheap IoT Wi-Fi modules (Tuya/Smart-Life on ESP/lwIP, Deye/Solarman solar loggers, …) behaved oddly on
this firmware: they associate to the AP fine, but are slow or unreliable to come online / reach their cloud —
while connecting quickly to a phone hotspot or a "dumb" range extender. These are notes from one real
household, not a definitive teardown — the **fixes below are what empirically worked for us**; some of the
**root-cause explanations are best-effort guesses** and are flagged as such. None of this is specific to the
MTK SDK — the DNS bits apply to vanilla OpenWrt + AdGuard Home too.

> **Terminology — read this first.** In every example below, **`iot` is the name of a dedicated firewall
> zone / network we created** just for smart-home gear (subnet `192.168.5.0/24`, router IP `192.168.5.1`,
> Wi-Fi VAP `<iot-vap>`). Those names are **specific to our setup**. Wherever you see `iot`, `192.168.5.x`,
> or `<iot-vap>`, substitute **your own** zone name / subnet / interface. You don't strictly need a separate
> IoT network, but having one is what lets the per-subnet DNS rules below stay clean and not touch your main
> LAN.

### 1. Device sends DNS to a stale/foreign resolver (Tuya, e.g. Kogan aircon)
We saw a Tuya aircon keep querying a DNS server that wasn't on our network — it looked like an address left
over from the phone hotspot it was last paired on (a carrier CGNAT `10.x`). On the router those queries went
unanswered, so it couldn't resolve the Tuya cloud. Check with:
```
cat /proc/net/nf_conntrack | grep <device-ip>   # e.g. dst=10.x.x.x dport=53 [UNREPLIED]
```
We don't know how long the device would have clung to that stale resolver — quite possibly it would have
recovered on its own once some internal cache/lease expired, and we simply weren't patient enough. Either
way, the reliable fix is to **redirect all IoT DNS to the local resolver** so it doesn't matter what server a
device tries to use:
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
After this the device came online immediately instead of waiting.

### 2. AdGuard Home + IPv6 AAAA when the WAN has no IPv6  (applies to vanilla OpenWrt too)
If your WAN has **no working IPv6** (`ifstatus wan6` → `"up": false`) but the LAN still advertises IPv6 RA,
an IPv6-capable IoT device may try the cloud over **IPv6 first** and stall because there's no route out.
AdGuard Home doesn't strip AAAA (IPv6) records unless you tell it to, so the device keeps receiving an IPv6
answer it then prefers. We observed a Tuya device "connect briefly then drop" with a roughly periodic
self-deauth in this state; it was fine on a phone hotspot, which hands out plain IPv4. We can't claim IPv6 is
the only factor, but steering the IoT devices onto IPv4 for DNS resolved it for us and is low-risk to try.

You have two ways to keep the IoT devices on IPv4 for the cloud:
- **Blunt (whole network):** turn off IPv6 resolving in AdGuard Home — *Settings → DNS settings → "Disable
  resolving of IPv6 addresses"* (`aaaa_disabled: true`). Simple, but it kills AAAA for **every** client.
- **Narrow (what we did):** make AdGuard return empty AAAA (NODATA) for the **IoT subnet only**, so the main
  LAN keeps full IPv6. Keep IPv6 RA on (devices still get an address); they just can't resolve a cloud AAAA.
  In AdGuard Home → *Filters → Custom filtering rules*, add (swap in your IoT subnet):
```
/.*/$client=192.168.5.0/24,dnstype=AAAA,dnsrewrite=NOERROR
```
Verify (query sourced from the IoT subnet):
```
nslookup -type=AAAA a1.tuyaeu.com 192.168.5.1   # empty answer (blocked)
nslookup -type=A    a1.tuyaeu.com 192.168.5.1   # returns IPv4  (works)
```
> Editing `/etc/adguardhome.yaml` by hand? **Stop AdGuard first** (`service adguardhome stop`) — it rewrites
> the file on shutdown and will overwrite your edit. Add the rule under `user_rules:`, then start it again.

### 3. A logger that wouldn't work without IPv6 RA (Deye/Solarman) — mechanism unclear
Counter-intuitively, our Deye solar logger did the **opposite** of the Tuya devices. With IPv6 fully disabled
on the IoT network it would associate and get a DHCP lease but then sit **completely silent** (no DNS, no
traffic at all — `tcpdump -i <iot-if>` showed nothing). Re-enabling IPv6 RA/SLAAC on that network and forcing
a re-join brought it straight back to its cloud.

We genuinely **don't have a confirmed explanation** for this, and there's an open contradiction we never
resolved: the same logger works happily on a plain **IPv4-only range extender** with no IPv6 at all, yet on
this router it only worked once IPv6 RA was present. So "this device requires IPv6" is too strong a
conclusion — treat it as an observation specific to our setup. If you have an IPv6-aware logger misbehaving,
it's worth trying RA **on** (combined with the AAAA block in #2, which keeps the IPv4-only devices safe):
```
# IoT network: advertise RA/SLAAC but stay ULA-only (no global prefix needed)
uci set network.iot.ip6assign='64'
uci set network.iot.delegate='0'
uci set dhcp.iot.ra='server'
uci commit network; uci commit dhcp
/etc/init.d/network reload; /etc/init.d/odhcpd restart
```

### Misc IoT notes
- First-time **Tuya pairing** sometimes failed directly on the router SSID; pairing the device against a phone
  hotspot (same SSID/password) and then switching the hotspot off worked as a one-time workaround.
- To nudge a stuck device into a clean re-join without physical access (mtwifi):
  `iwpriv <iot-vap> set DisConnectSta=<MAC>`.
- Harmless IoT-VAP comfort settings for fussy cheap chips (per-VAP, leaves main radios untouched): turn off
  `ieee80211k`, `ieee80211r`, `ofdma_dl/ul`, `mumimo_dl/ul`, `amsdu` on the IoT `wifi-iface`. These didn't
  fix anything on their own for us, but they don't hurt.

## USB Phone Tethering as a Backup WAN (NBN-first failover)

The image includes everything needed to plug a phone into the router's USB port and use its tethering as a **backup** WAN:

| Package | Purpose |
|---|---|
| `kmod-usb-net-rndis`, `kmod-usb-net-cdc-ether` | Android USB tethering (RNDIS, most phones) |
| `kmod-usb-net-cdc-ncm` | Android USB tethering on phones that use NCM instead of RNDIS |
| `kmod-usb-net-ipheth`, `usbmuxd` | iPhone USB tethering (Personal Hotspot). usbmuxd does the "Trust This Computer" pairing; records are stored in `/etc/lockdown` and survive sysupgrade |
| `mwan3`, `luci-app-mwan3`, `ip-full` | Health-checks each WAN and fails over / fails back. Status page: **Status → MultiWAN Manager** |

Kernel modules **cannot** be added later with `opkg` on this image: the MTK SDK kernel has a different struct layout from official ImmortalWrt builds (same `6.6.x` vermagic, different offsets), so official kmods would load and then corrupt memory. Anything kernel-side must be built here.

`Files/` is copied into the image rootfs at build time. `Files/etc/hotplug.d/net/05-tether-rename` renames tethering NICs so MTK HNAT leaves them alone (see gotchas). `Files/etc/uci-defaults/99-mwan3-stock-off` disables mwan3 on a fresh flash while its config is still the package's stock sample (whose default `last_resort` would make traffic unreachable if tracking failed). A real mwan3 config kept across sysupgrade is not touched.

### How it behaves

Once the router-side configuration below is in place:

- **Normal operation:** all traffic uses the main WAN (NBN on `eth1`). A phone plugged into USB with tethering on is only a standby link. The router pings through it about once a minute (roughly 0.5 MB of mobile data a day) and sends nothing else over it.
- **Failover:** when the main WAN has **no internet for about 20 seconds**, traffic moves to the phone. It doesn't matter whether the cable was unplugged, NBN is down, or the WAN got no DHCP lease. The router judges by pinging 1.1.1.1, 8.8.8.8 and 9.9.9.9 *through the WAN port itself*, not by link state. If no phone is tethering at that moment, there is simply no internet.
- **Failback:** the main WAN keeps being tested in the background while the phone is in use. After **about 60 seconds of clean checks**, traffic moves back to it, **even if the phone is still plugged in and tethering**, to save mobile data.
- **Each switch resets existing connections**, so they re-establish on the new path instead of hanging. Expect video calls and downloads to blip once.
- **Who may use the phone** is decided by firewall forwardings into the `tether` zone. In our setup `lan` and `iot` may; `lan2` may not, so lan2 simply has no internet while on the phone.
- **IPv6** only exists through the main WAN. While on the phone, `wan6` is taken down and the router stops advertising an IPv6 default route, so LAN devices fall back to IPv4. IPv6 comes back on failback.
- **DNS keeps working:** AdGuard Home's upstreams are plain public resolvers (DNS-over-TLS to 1.1.1.1), which are reachable over the phone too.
- **Inbound connections stop working on the phone.** Port forwards, WireGuard clients dialling home and DDNS are all affected, because mobile data sits behind carrier-grade NAT. A tunnel can survive if the *router* dials out to a server with a public IP and keepalive enabled; see the WireGuard gotcha below.
- **The phone shows up as `tether0`, and an iPhone as `iphone0`, not as `usb0`/`eth2`.** `05-tether-rename` renames them the moment they are plugged in, because MTK's hardware NAT otherwise hijacks the phone's TCP/UDP traffic (see the HNAT gotcha below). After plugging in, it can take **30–60 seconds** before the MultiWAN page shows the phone link online. If the main WAN is completely down, traffic already flows through the phone during that time.
- **Watching it:** LuCI → **Status → MultiWAN Manager** shows each link as online or offline and which one carries traffic (e.g. `wan (100%)` or `usbwan (100%)`).

### Router-side configuration (not part of the image)

The behaviour lives in `/etc/config/{network,firewall,mwan3}` and `/etc/mwan3.user`, which are kept across sysupgrade. On a fresh flash, recreate it:

- **network**: `usbwan` (proto `dhcp`, device `tether0`, metric `20`) for Android, and `iphonewan` (proto `dhcp`, device `iphone0`, metric `30`) for iPhone. These names come from `Files/etc/hotplug.d/net/05-tether-rename` (see the HNAT gotcha below); without it the kernel would call them `usb0` and `eth2`.
- **firewall**: a separate zone `tether` (networks `usbwan iphonewan`, input/forward `REJECT`, `masq` + `mtu_fix`) with forwardings from the zones allowed to use mobile data (e.g. `lan`, `iot`). Zones with no forwarding into `tether` (e.g. `lan2`) simply have no internet while on the phone — no extra rules needed. Add an `Allow-DHCP-Renew` rule for `tether` (udp/68).
- **mwan3**: one policy, `wan` member metric 1, `usbwan`/`iphonewan` members metric 2, `last_resort default` (fall back to the main table rather than blackholing), and a single IPv4 rule using it. Track `wan` with several public IPs every 5 s (`down 4` ≈ 20 s to fail over, `up 12` ≈ 60 s of clean checks before failing back) with `flush_conntrack connected disconnected`; track the phone links slowly (`interval 60`) to save mobile data.
- **`/etc/mwan3.user`** (optional): take `wan6` down on `wan` `disconnected` and back up on `connected` (use `ubus call network.interface.wan6 up/down`, not `ifup`, which bounces an already-up interface), so LAN clients drop the NBN IPv6 prefix while on the phone.

Gotchas found while setting this up:

- **MTK HNAT breaks USB tethering unless the NIC is renamed.** HNAT adopts any device whose name starts with an `ext-devices-prefix` from the device tree (`usb`, `wwan`, `rmnet`, `eth2`, `eth3`, `eth4` on MT7986) as an "external device" and loops its received TCP/UDP through the PPE, tagged with a 12-bit VLAN ID of `ifindex & 0xFFF`. On the way back it looks the device up by `ifindex == vlan`, which can never match once the ifindex exceeds 4095 (long uptime, replugs, VPN restarts) — the replies are then emitted onto the LAN bridge instead. Symptom: ICMP works (not HNAT-handled) but DNS/TCP over the phone silently fail. `05-tether-rename` renames `rndis_host`/`cdc_ether`/`cdc_ncm` NICs to `tether0` and `ipheth` to `iphone0` on hotplug `add`, before netifd brings them up, so HNAT never adopts them and the CPU routes them like any other interface. Note `cdc_ether` also covers many USB-Ethernet dongles, which will therefore also become `tether0`.
- netifd processes interface hotplug events one at a time, and each `ifup`/`ifdown` triggers firewall reloads and other hooks, so mwan3 may only mark a new phone link online 30-60 s after it comes up. Traffic still flows meanwhile via the main table's default route (metric 20) when NBN is down.
- Install-time: `opkg install mwan3` immediately enables and starts it with the stock sample config. When adding it by hand, use `IPKG_NO_SCRIPT=1 opkg install …` and start it yourself once configured.
- WireGuard peers with an `endpoint_host` get a pinned host route via the WAN that was active at `ifup`, which bypasses mwan3 — the tunnel would stay on a dead NBN. Set `option nohostroute '1'` on the WireGuard interface (safe unless the tunnel carries a default route).
- `/etc/init.d/network reload` does not apply changes to WireGuard *peer* sections; run `ifup <wg-interface>`.
- Phones usually need USB tethering re-enabled after each replug; Android's developer option *Default USB configuration → USB tethering* makes it automatic. The router's USB port supplies ~0.9 A, so heavy tethering may only slow the battery drain rather than charge.
