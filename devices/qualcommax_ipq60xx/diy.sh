#!/bin/bash

shopt -s extglob

SHELL_FOLDER=$(dirname $(readlink -f "$0"))

rm -rf package/boot package/firmware/ipq-wifi target/linux/generic target/linux/qualcommax package/firmware/ath11k-firmware package/kernel/mac80211 package/kernel/nat46

git_clone_path 25.12-nss https://github.com/LiBwrt/openwrt-6.x target/linux/generic target/linux/qualcommax package/boot package/firmware/ipq-wifi package/firmware/ath11k-firmware package/kernel/mac80211 package/kernel/nat46

wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/include/image-commands.mk -P include/
wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/config/Config-ipq.in -P config/
wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/Config.in -P ./

rm -rf feeds/kiddin9/shortcut-fe 

git clone https://github.com/laipeng668/nss-packages.git -b NSS-LibWrt package/nss-packages
git clone https://github.com/qosmio/sqm-scripts-nss.git package/sqm-scripts-nss

sed -i "/ECM_INTERFACE_RAWIP_ENABLE/d"  package/nss-packages/qca-nss-ecm/Makefile
rm -rf package/nss-packages/nss-userspace-oss

sed -i "s/luci uboot-envtools wpad-openssl/luci uboot-envtools wpad-mbedtls/" target/linux/qualcommax/Makefile

# ============================================================
# 以下为 AX1800 Pro（硬改 1G 运存）定制补丁
# 执行时机：devices/common/diy.sh 之后，此时 target/linux/qualcommax
# 已被替换成 LibWrt 的 NSS 树、feeds 已克隆安装完毕。
# 任何一条匹配不上都直接退出，不静默跳过（否则会编出一个“看起来正常
# 但补丁没生效”的固件）。
# ============================================================
die() { echo "[x] $*" >&2; exit 1; }

# ---- 1. 无线内存档：8 VDEV / 128 peers → 16 VDEV / 512 peers ----
DTS=target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6000-re-ss-01.dts
[ -f "$DTS" ] || die "找不到 $DTS"
grep -q 'qcom,ath11k-fw-memory-mode = <1>' "$DTS" \
  || die "ath11k-fw-memory-mode 不是 <1>（上游改过？），先人工看 $DTS"
sed -i 's/qcom,ath11k-fw-memory-mode = <1>/qcom,ath11k-fw-memory-mode = <0>/' "$DTS"
echo "[+] 无线档 -> qcom,ath11k-fw-memory-mode = <0>"

# ---- 2. q6 保留区：55MiB → 85MiB（给 NSS 无线留够内存）----
DTSI=target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
[ -f "$DTSI" ] || die "找不到 $DTSI"
grep -q 'reg = <0x0 0x4ab00000 0x0 0x3700000>' "$DTSI" \
  || die "q6_region 不是 0x3700000（上游改过？），先人工看 $DTSI"
sed -i 's/reg = <0x0 0x4ab00000 0x0 0x3700000>/reg = <0x0 0x4ab00000 0x0 0x5500000>/' "$DTSI"
echo "[+] q6 保留区 -> 85MiB"

# ---- 3. 网络：Kwrt 把默认 LAN 改成 10.0.0.1，改回 192.168.1.1 ----
CG=package/base-files/files/bin/config_generate
[ -f "$CG" ] || die "找不到 $CG"
sed -i 's|ipad=${ipaddr:-"10\.0\.0\.1"}|ipad=${ipaddr:-"192.168.1.1"}|' "$CG"
grep -q 'ipad=${ipaddr:-"192.168.1.1"}' "$CG" || die "默认 LAN IP 没改回来（$CG）"
echo "[+] 默认 LAN -> 192.168.1.1"

# 主机名回 OpenWrt 官方默认（上游 common/diy.sh 把 OpenWrt 全替成了 Kwrt）
sed -i "s/hostname='Kwrt'/hostname='OpenWrt'/" "$CG"
grep -q "hostname='OpenWrt'" "$CG" || die "主机名没改成功（$CG）"
echo "[+] 主机名 -> OpenWrt"

# ---- 4. 从默认包里摘掉 Kwrt 强塞的东西 ----
# advancedplus 是 Kwrt 的“进阶设置”，推广载体；
# footstrap-files 是网页版文件编辑器（带 prism 高亮，体积偏大），本机不需要。
# 两者都被 common/diy.sh 塞进了 include/target.mk 的 DEFAULT_PACKAGES，
# 只在 .config 里写 is not set 是压不住的，defconfig 会把它重新加回来。
if [ -f include/target.mk ]; then
  for pkg in luci-app-advancedplus luci-app-footstrap-files; do
    sed -i "s/$pkg //g; s/ $pkg//g" include/target.mk
    grep -q "$pkg" include/target.mk && die "$pkg 仍在 DEFAULT_PACKAGES 里"
    echo "[+] 已从 DEFAULT_PACKAGES 摘掉 $pkg"
  done
fi

# ---- 4.1 去掉作者署名（/etc/os-release 的 OPENWRT_RELEASE 字段）----
# 上游 common/diy.sh: sed "s#%C\"#%C by Kiddin'\"#" package/base-files/files/etc/os-release
# 注意 /etc/os-release 是符号链接 -> ../usr/lib/os-release，sed -i 默认会把链接替换成
# 普通文件，这里用 --follow-symlinks 保形。
# banner 里的 %C 是 VERSION_CODE（构建日期），不含作者名，与这里无关。
for f in package/base-files/files/usr/lib/os-release package/base-files/files/etc/openwrt_release; do
  [ -f "$f" ] || continue
  sed --follow-symlinks -i "s/ by Kiddin'//g; s/ by Kiddin//g" "$f"
  if grep -q 'Kiddin' "$f"; then die "作者署名没清干净（$f）"; fi
  echo "[+] 已清理作者署名 -> $f"
done

# ---- 5. 确认主题与插件真的在源码树里 ----
[ -d feeds/kiddin9/luci-theme-argon ] || die "feeds/kiddin9/luci-theme-argon 不存在，主题装不上"
[ -d feeds/kiddin9/luci-app-openclash ] || die "feeds/kiddin9/luci-app-openclash 不存在，代理装不上"
echo "[+] argon 与 openclash 源码均在"

echo "[✓] AX1800 Pro 定制补丁全部生效"
