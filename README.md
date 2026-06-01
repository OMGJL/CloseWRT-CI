# CloseWRT-CI
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
