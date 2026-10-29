#!/bin/sh
# WiFi 起不来时的现场取证。只读，不改任何配置、不动无线状态。
#
# 用法一（路由器上一条命令）：
#   uclient-fetch -O - https://raw.githubusercontent.com/Living877/kwrt-ax1800/main/scripts/wifi-diag.sh | sh
# 用法二（拉不下来时）：把下面 { ... } 整段粘进 SSH 回车即可。
#
# 输出会同时存进 /tmp/wifi.txt，方便整段复制回来。
#
# 现在已经走过两关：Q6 起不来（已过）→ cal 文件缺失（-110）→ NSS SOC 注册失败（-22）。
# 所以这份取证的重点从内存保留区挪到了「固件文件 + nss 模块状态」。

{
	printf '\n== 1 固件版本\n'
	grep -E 'DESCRIPTION|ARCH' /etc/openwrt_release 2>/dev/null
	printf '\n== 2 内核与机型\n'
	uname -r
	cat /tmp/sysinfo/model 2>/dev/null
	awk '{printf "本次已开机 %d 分钟\n", $1/60}' /proc/uptime

	printf '\n== 3 无线固件文件（cal 在不在、是不是后来才放的）\n'
	ls -l /lib/firmware/ath11k/IPQ6018/hw1.0/ 2>/dev/null || echo '(目录不存在)'
	ls -l /lib/firmware/IPQ6018/ 2>/dev/null | head -6

	printf '\n== 4 无线设备（空 = ath11k 没注册出 phy）\n'
	ls /sys/class/ieee80211/ 2>/dev/null || echo '(无)'

	printf '\n== 5 NSS 相关模块与包\n'
	lsmod 2>/dev/null | grep -iE 'nss|ecm|ath11k|qca' | sort
	opkg list-installed 2>/dev/null | grep -iE 'nss|ecm|ath11k|ipq-wifi'

	printf '\n== 6 dmesg（ath11k / nss / cal / board）\n'
	dmesg | grep -iE 'ath11k|nss|remoteproc|qmi|cal-|board (data|file)' | tail -45

	printf '\n== 7 wpad / hostapd 是否在跑\n'
	ps | grep -E 'wpad|hostapd' | grep -v grep || echo '(没在跑)'

	printf '\n== 8 wireless 配置\n'
	uci show wireless 2>/dev/null | head -25

	printf '\n== 9 内存与链路\n'
	free -m
	ip -br link 2>/dev/null

	printf '\n== 10 MTD 分区表（cal 固化要用）\n'
	cat /proc/mtd 2>/dev/null || echo '(读不到)'

	printf '\n== 完，整段复制回去即可\n'
} 2>&1 | tee /tmp/wifi.txt
