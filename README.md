# CloseWRT-CI
Compile Padavan's Immortal WRT Firmware

PADAVANONLY-24.10
https://github.com/padavanonly/immortalwrt-mt798x-24.10.git

# Note:

This project only supports compiling closed-source MTK SDK projects that contain a defconfig directory.

# Firmware Overview:

The firmware is automatically compiled at 3 AM Sydney time every Tuesday.

The time shown in the firmware information is the build start time, which helps to verify the upstream source code commit time.

The official mainline OpenWRT UBoot is compatible with this firmware, please follow their flash instruction.

# Directory Overview:

workflows — Custom CI configurations

Scripts — Custom scripts

Config — Custom configurations

# Quirks:

This firmware is built by padavanonly, forking ImmortalWRT, then added MTK closed source driver. Hence, it have inherited all ImmortalWRT's quirk, as well as padavanonly's quirk.

Specifically, for setting up AdguardHome:

1. you'll need to ssh into the router, vi /etc/config/adguardhome and modify the enabled line to 
    `option enabled '1'`
    This quirk is not present in OpenWRT but is in ImmortalWRT (source : https://github.com/immortalwrt/packages/blob/master/net/adguardhome/files/adguardhome.config)

2. on dnsmasq, there's a build in script from Padavanonly, (source https://github.com/padavanonly/immortalwrt-mt798x-6.6/blob/2806544a5a38283c6e778fa0a91e955e27e9987e/package/network/services/dnsmasq/files/dnsmasq.init#L1278)
```
	if [ "$dns_redirect" = 1 ]; then
		nft add table inet dnsmasq
		nft add chain inet dnsmasq prerouting "{ type nat hook prerouting priority -95; policy accept; }"
		nft add rule inet dnsmasq prerouting "meta nfproto { ipv4, ipv6 } udp dport 53 counter redirect to :$dns_port comment \"DNSMASQ HIJACK\""
	fi
```
the way to work around this is:
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