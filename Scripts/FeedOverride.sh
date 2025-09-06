#!/bin/bash

#getting separate AdguardHome package, since ImmortalWRT's one is broken

echo "[AGH Override] Preparing custom feed for official AdGuardHome..."

# This script is executed from the build root ('wrt/'), so all paths are relative to it.

# 1. Create a directory for our custom feed.
mkdir -p custom_feed

# 2. Clone the official OpenWrt packages repo into a temporary directory *outside* the build root.
git clone --depth=1 --filter=blob:none --sparse https://github.com/openwrt/packages.git ../openwrt_packages_temp

# 3. Use a subshell to perform sparse-checkout and move the package.
(
  cd ../openwrt_packages_temp && \
  git sparse-checkout set net/adguardhome && \
  # 4. Move the official AdGuardHome package into our custom feed directory inside 'wrt'.
  mv net/adguardhome ../wrt/custom_feed/
)

# 5. Clean up the temporary clone directory.
rm -rf ../openwrt_packages_temp

# 6. Add the custom feed to feeds.conf.default. The build system prioritizes feeds
# listed later in the file, ensuring our version is used over any other.
# We use an absolute path ($PWD) which resolves to the 'wrt' directory during the run.
echo "src-link custom_override $PWD/custom_feed" >> feeds.conf.default

echo "[AGH Override] Custom feed is configured. The build system will now use the official AdGuardHome package."