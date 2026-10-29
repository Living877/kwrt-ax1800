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

np=$(ls /sys/class/ieee80211/ 2>/dev/null | wc -w)
if [ "$np" -ge 2 ]; then ok "phy $np 个"; else no "phy $np 个(期望2)"; fi
nw=$(iw dev 2>/dev/null | grep -c Interface)
if [ "$nw" -ge 2 ]; then ok "无线接口 $nw 个"; else no "无线接口 $nw 个(期望2)"; fi
ssid=$(uci -q show wireless 2>/dev/null | grep -o "ssid='[^']*'" | head -1)
if [ -n "$ssid" ]; then ok "$ssid"; else no "无SSID配置"; fi
ps w 2>/dev/null | grep -q '[h]ostapd'
if [ $? -eq 0 ]; then ok "hostapd运行中"; else no "hostapd未运行"; fi

info "rootfs $(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2"("$5")"}')"
info "内存 $(free | awk '/^Mem:/{printf "%d/%dMB",$3/1024,$2/1024}')"

if [ -f /usr/lib/lua/luci/controller/store.lua ]; then ok "iStore控制器在"; else no "缺store.lua"; fi
pm=$(opkg list-installed 2>/dev/null | grep -c '^luci-app-package-manager')
if [ "$pm" = "0" ]; then ok "package-manager已移除"; else no "package-manager仍在"; fi

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
