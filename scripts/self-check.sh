#!/bin/sh
# kwrt-ax1800 固件一键自检（busybox ash 兼容）
# 用法：uclient-fetch -O - <raw地址> | sh ；或整体粘贴执行
echo "==== kwrt-ax1800 自检 $(date '+%F %T') 开机$(awk '{printf "%.0f分", $1/60}' /proc/uptime) ===="
OK=0
NO=0
ok() { OK=$((OK+1)); echo "  [OK] $1"; }
no() { NO=$((NO+1)); echo "  [!!] $1"; }
info() { echo "  [--] $1"; }

echo "---- banner ----"
cat /etc/banner 2>/dev/null | sed 's/^/  /'

m=$(cat /tmp/sysinfo/model 2>/dev/null)
echo "$m" | grep -q 'RE-SS-01'
if [ $? -eq 0 ]; then ok "机型 $m"; else no "机型 ${m:-未知}"; fi

info "系统 $(grep '^DISTRIB_DESCRIPTION' /etc/openwrt_release 2>/dev/null | cut -d= -f2- | tr -d "'")"
info "内核 $(uname -r)"

grep -q '^root:[^:!*]' /etc/shadow
if [ $? -eq 0 ]; then ok "root 密码已设置"; else no "root 未设密码"; fi

rb=$(uci -q get dhcp.@dnsmasq[0].rebind_protection)
if [ "$rb" = "1" ]; then ok "rebind保护=1"; else no "rebind保护=${rb:-无}"; fi
ls=$(uci -q get dhcp.@dnsmasq[0].localservice)
if [ "$ls" = "1" ]; then ok "localservice=1"; else no "localservice=${ls:-无}"; fi
dr=$(uci -q get dhcp.@dnsmasq[0].dns_redirect)
if [ "$dr" = "0" ]; then ok "dns_redirect=0"; else no "dns_redirect=${dr:-无}"; fi

cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
echo "$cc" | grep -q bbr
if [ $? -eq 0 ]; then ok "拥塞控制 $cc"; else no "拥塞控制 ${cc:-无}(期望bbr)"; fi

fc=$(uci -q get firewall.@defaults[0].fullcone)
if [ "$fc" = "1" ]; then
	nft list ruleset 2>/dev/null | grep -q 'fullcone'
	if [ $? -eq 0 ]; then ok "全锥NAT已生效"; else no "全锥NAT开关=1但规则里没有(fw4未打补丁或模块缺失)"; fi
else
	no "全锥NAT未开(fullcone=${fc:-无})"
fi

lsmod | grep -q ecm
if [ $? -eq 0 ]; then ok "NSS ECM已加载"; else no "NSS ECM未加载"; fi
lsmod | grep -q qca_nss_drv
if [ $? -eq 0 ]; then ok "NSS驱动已加载"; else no "NSS驱动未加载"; fi

# NSS 固件：包在、文件不在 或者 驱动 -110 超时，表现都是"能上网但没有硬件加速"，
# 不报错、不变慢到明显察觉，只能靠 dmesg 里那行 probe failed 才发现
if [ -s /lib/firmware/qca-nss0.bin ]; then ok "NSS固件qca-nss0.bin在"; else no "缺/lib/firmware/qca-nss0.bin"; fi
if [ -x /etc/init.d/nss-fw-early ]; then ok "nss-fw-early(开机早期补别名)在"; else no "缺/etc/init.d/nss-fw-early"; fi
ft=""
for p in /sys/class/firmware/timeout /sys/module/firmware_class/parameters/loading_timeout /sys/module/firmware_class/parameters/timeout
do
	if [ -r "$p" ]; then ft=$(cat "$p" 2>/dev/null); break; fi
done
if [ "$ft" = "10" ]; then ok "固件超时10s(防级联)"; else no "固件超时=${ft:-读不到}(期望10，60s会级联拖慢开机)"; fi
dmesg 2>/dev/null | grep -q "qca-nss 39000000.nss: probe with driver qca-nss failed"
if [ $? -eq 0 ]; then no "qca-nss probe失败(-110)，NSS硬件加速没起来"; else ok "qca-nss probe正常"; fi

# 无线校准数据：ath11k 靠它出 phy。缺这份文件 = 没有 phy = 整个无线功能消失，
# 且内核要等满 60s 才报 -110，开机被拖长 2 分钟以上
CAL=/lib/firmware/ath11k/IPQ6018/hw1.0/cal-ahb-c000000.wifi.bin
if [ -s "$CAL" ]; then ok "cal data在($(wc -c < "$CAL")字节)"; else no "缺 cal-ahb-c000000.wifi.bin，无线必挂"; fi
if [ -f /etc/hotplug.d/firmware/11-ath11k-caldata ]; then ok "caldata热插拔脚本在"; else no "缺11-ath11k-caldata"; fi
if [ -x /etc/init.d/caldata-early ]; then ok "caldata-early(开机早期提取)在"; else no "缺/etc/init.d/caldata-early"; fi

# ART 分区（0:ART / mmcblk0p15）：整机唯一单份、不可重建，cal 就是从这块切的。
# 顺带比一次 MD5，证明固件里的 cal 真是本机 ART 来的，不是别处残留的
if [ -r /sys/class/block/mmcblk0p15/size ]; then
	art_n=$(cat /sys/class/block/mmcblk0p15/size 2>/dev/null)
	art_s=$(cat /sys/class/block/mmcblk0p15/start 2>/dev/null)
	ok "ART分区在(p15 起始${art_s} ${art_n}扇区)"
	dd if=/dev/mmcblk0p15 of=/tmp/.scart bs=4096 skip=1 count=16 2>/dev/null
	if [ -s /tmp/.scart ]; then
		a=$(md5sum /tmp/.scart 2>/dev/null | cut -d' ' -f1)
		b=$(md5sum "$CAL" 2>/dev/null | cut -d' ' -f1)
		if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "cal与本机ART一致"; else no "cal与ART的MD5不符(cal来源可疑)"; fi
	else
		no "读不出ART内容，分区可能是空的"
	fi
	rm -f /tmp/.scart
else
	no "找不到mmcblk0p15，分区表被改过？"
fi

np=$(ls /sys/class/ieee80211/ 2>/dev/null | wc -w)
if [ "$np" -ge 2 ]; then ok "phy $np 个"; else no "phy $np 个(期望2)"; fi
nw=$(iw dev 2>/dev/null | grep -c Interface)
if [ "$nw" -ge 2 ]; then ok "无线接口 $nw 个"; else no "无线接口 $nw 个(期望2)"; fi
ssid=$(uci -q show wireless 2>/dev/null | grep -o "ssid='[^']*'" | head -1)
if [ -n "$ssid" ]; then ok "$ssid"; else no "无SSID配置"; fi
ps w 2>/dev/null | grep -q '[h]ostapd'
if [ $? -eq 0 ]; then ok "hostapd运行中"; else no "hostapd未运行"; fi

# WAN 载波：NO-CARRIER 是最常见也最容易误判成"固件坏了"的"故障"
if [ -e /sys/class/net/wan ]; then
	wanlink=$(cat /sys/class/net/wan/carrier 2>/dev/null)
	if [ "$wanlink" = "1" ]; then ok "WAN有载波"; else no "WAN无载波(网线没插,或插在LAN口)"; fi
fi

info "rootfs $(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2"("$5")"}')"
info "内存 $(free | awk '/^Mem:/{printf "%d/%dMB",$3/1024,$2/1024}')"

if [ -f /usr/lib/lua/luci/controller/store.lua ]; then ok "iStore控制器在"; else no "缺store.lua"; fi
# luci-app-package-manager 被 luci-nginx / luci 硬依赖，摘不掉（2026-10-30 实机确认），
# 所以只验两件事：官方页是否已挪到系统下、iStore 的菜单标题是否改对了
if grep -q '"admin/system/package-manager"' /usr/share/luci/menu.d/luci-app-package-manager.json 2>/dev/null; then
	ok "软件包已挪到系统下"
else
	no "package-manager 还占 admin/package-manager，会把 iStore 顶掉"
fi
if grep -q '"iStore", 30' /usr/lib/lua/luci/controller/store.lua 2>/dev/null; then
	ok "iStore菜单标题正确"
else
	no "store.lua 里菜单标题不是 iStore"
fi

# controller 里 require 的 luci.* 模块必须真的存在，否则 dispatcher 建菜单时会抛
# "module 'luci.x' not found"，整个 LuCI 500、网页全打不开（netstat 就是这么中招的）
miss=""
for f in /usr/lib/lua/luci/controller/*.lua; do
	[ -f "$f" ] || continue
	for m in $(grep -o 'require("luci\.[a-zA-Z0-9_.]*")' "$f" 2>/dev/null | sed 's/^require("//;s/")$//'); do
		p="/usr/lib/lua/$(echo "$m" | tr '.' '/').lua"
		if [ ! -f "$p" ]; then
			miss="$miss $(basename "$f")->$m"
		fi
	done
done
if [ -z "$miss" ]; then ok "LuCI controller 依赖齐全"; else no "controller 缺模块:$miss"; fi

lst=$(netstat -tln 2>/dev/null || ss -tln 2>/dev/null)
echo "$lst" | grep -q ':22 '
if [ $? -eq 0 ]; then ok "SSH:22"; else no "SSH:22未监听"; fi
echo "$lst" | grep -q ':80 '
if [ $? -eq 0 ]; then ok "HTTP:80"; else no "HTTP:80未监听"; fi

y=$(date +%Y)
if [ "$y" -ge 2026 ]; then ok "时间 $(date '+%F %T')"; else no "时间异常(未NTP同步)"; fi

echo "==== 结果：通过 $OK / 异常 $NO ===="
if [ "$NO" = "0" ]; then echo ">>> 未发现明显问题"; else echo ">>> 把上面 [!!] 行贴回来"; fi
