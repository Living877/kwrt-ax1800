#!/bin/sh
# WiFi 起不来时的现场取证。只读，不改任何配置、不动无线状态。
#
# 用法一（路由器上一条命令）：
#   uclient-fetch -O - https://raw.githubusercontent.com/Living877/kwrt-ax1800/main/scripts/wifi-diag.sh | sh
# 用法二（拉不下来时）：把下面 { ... } 整段粘进 SSH 回车即可。
#
# 输出会同时存进 /tmp/wifi.txt，方便整段复制回来。

{
	printf '\n== 1 固件版本\n'
	grep -E 'DESCRIPTION|ARCH' /etc/openwrt_release 2>/dev/null
	printf '\n== 2 内核与机型\n'
	uname -r
	cat /tmp/sysinfo/model 2>/dev/null
	printf '\n== 3 无线设备（空 = ath11k 没注册出 phy）\n'
	ls /sys/class/ieee80211/ 2>/dev/null || echo '(无)'
	printf '\n== 4 设备树保留区（地址就在节点名里）\n'
	ls /sys/firmware/devicetree/base/reserved-memory/ 2>/dev/null || echo '(读不到)'
	printf '\n== 5 /proc/iomem 里的无线相关区段\n'
	grep -iE 'q6|mhi|wcn|ath|reserv' /proc/iomem 2>/dev/null
	printf '\n== 6 dmesg（ath11k / remoteproc / 固件加载）\n'
	dmesg | grep -iE 'ath11k|remoteproc|mhi|wcn|q6|firmware|wifi' | tail -40
	printf '\n== 7 wpad / hostapd 是否在跑\n'
	ps | grep -E 'wpad|hostapd' | grep -v grep || echo '(没在跑)'
	printf '\n== 8 wireless 配置\n'
	uci show wireless 2>/dev/null | head -25
	printf '\n== 9 内存与链路\n'
	free -m
	ip -br link 2>/dev/null
	printf '\n== 完，整段复制回去即可\n'
} 2>&1 | tee /tmp/wifi.txt
