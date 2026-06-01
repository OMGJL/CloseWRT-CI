#!/bin/bash

#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

# Find mtwifi.sh (the lib/wifi version, not the netifd version)
# Use find like the luci patches above — hardcoded paths to package/mtk/ are not
# reliably present in all build environments despite being in the upstream repo.
WIFI_FILE=$(find ./package/ -name "mtwifi.sh" -not -path "*/netifd/*" 2>/dev/null | head -1)
if [ -z "$WIFI_FILE" ]; then
	echo "WARNING: mtwifi.sh not found, skipping WIFI patches"
else
	echo "Patching WIFI settings: $WIFI_FILE"
	#修改WIFI名称
	sed -i "s/ImmortalWrt/$WRT_SSID/g" "$WIFI_FILE"
	#修改WIFI加密
	sed -i "s/encryption=.*/encryption='psk2+ccmp'/g" "$WIFI_FILE"
	#修改WIFI密码
	sed -i "/set wireless.default_\${dev}.encryption='psk2+ccmp'/a \\\t\t\t\t\t\set wireless.default_\${dev}.key='$WRT_WORD'" "$WIFI_FILE"
	#Change default country code from CN to AU
	sed -i 's/\.country=CN/.country=AU/' "$WIFI_FILE"
fi

#Fix AU 5GHz region mapping
#Region 0 = channels 36-64 + 149-165 (missing DFS band 100-140)
#Region 7 = channels 36-64 + 100-140 + 149-165 (full AU channel plan)
DEFS_FILE=$(find ./package/ -name "mtwifi_defs.lua" 2>/dev/null | head -1)
if [ -z "$DEFS_FILE" ]; then
	echo "WARNING: mtwifi_defs.lua not found, skipping AU region patch"
else
	echo "Patching AU 5GHz region: $DEFS_FILE"
	# Match lines containing "AU" and change region 5G from 0 to 7.
	# Avoids \[ bracket escaping which is not portable across sed implementations.
	sed -i '/AU/s/{ 1, 0 }/{ 1, 7 }/' "$DEFS_FILE"
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi
