#!/bin/sh
# kwrt-ax1800 固件一键自检（busybox ash 兼容）
# 用法：SSH 里整体粘贴执行；或先存文件再 sh /tmp/self-check.sh
echo "==== kwrt-ax1800 自检 $(date '+%F %T') 开机$(awk '{printf "%.0f分", $1/60}' /proc/uptime) ===="
OK=0; NO=0
ok(){ OK=$((OK+1)); echo "  [OK] $1"; }
no(){ NO=$((NO+1)); echo "  [!!] $1"; }
info(){ echo "  [--] $1"; }

echo "---- banner ----"
cat /etc/banner 2>/dev/null | sed 's/^/  /'

m=$(cat /tmp/sysinfo/model 2>/dev/null)
case "$m" in *RE-SS-01*|*AX1800*) ok "机型 $m" ;; *) no "机型 ${m:-未知}" ;; esac
info "系统 $(grep ^DISTRIB_DESCRIPTION /etc/openwrt_release 2>/dev/null | cut -d= -f2- | tr -d "'")"
info "内核 $(uname -r)"

h=$(sed -n 's/^root:\([^:]*\).*/\1/p' /etc/shadow)
case "$h" in ''|'!'*|'*'*) no "root 未设密码" ;; *) ok "root 密码已设置" ;; esac

rb=$(uci -q get dhcp.@dnsmasq[0].rebind_protection); [ "$rb" = 1 ] && ok "rebind保护=1" || no "rebind保护=${rb:-无}"
ls=$(uci -q get dhcp.@dnsmasq[0].localservice);       [ "$ls" = 1 ] && ok "localservice=1" || no "localservice=${ls:-无}"
dr=$(uci -q get dhcp.@dnsmasq[0].dns_redirect);       [ "$dr" = 0 ] && ok "dns_redirect=0" || no "dns_redirect=${dr:-无}"

cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
echo "$cc" | grep -q bbr && ok "拥塞控制 $cc" || no "拥塞控制 ${cc:-无}(期望bbr)"
lsmod | grep -q ecm && ok "NSS ECM已加载" || no "NSS ECM未加载"
lsmod | grep -q qca_nss_drv && ok "NSS驱动已加载" || no "NSS驱动未加载"

np=$(ls /sys/class/ieee80211/ 2>/dev/null | wc -w)
[ "$np" -ge 2 ] && ok "phy $np 个" || no "phy $np 个(期望2)"
nw=$(iw dev 2>/dev/null | grep -c Interface)
[ "$nw" -ge 2 ] && ok "无线接口 $nw 个" || no "无线接口 $nw 个(期望2)"
ssid=$(uci -q show wireless 2>/dev/null | grep -o "ssid='[^']*'" | head -1)
[ -n "$ssid" ] && ok "$ssid" || no "无SSID配置"
ps w 2>/dev/null | grep -q '[h]ostapd' && ok "hostapd运行中" || no "hostapd未运行"

info "rootfs $(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2"("$5")"}')"
info "内存 $(free -m | awk '/^Mem:/{print $3"/"$2"MB"}')"

[ -f /usr/lib/lua/luci/controller/store.lua ] && ok "iStore控制器在" || no "缺store.lua"
pm=$(opkg list-installed 2>/dev/null | grep -c '^luci-app-package-manager ')
[ "$pm" = 0 ] && ok "package-manager已移除" || no "package-manager仍在"

lst=$(netstat -tln 2>/dev/null || ss -tln 2>/dev/null)
echo "$lst" | grep -q ':22 ' && ok "SSH:22" || no "SSH:22未监听"
echo "$lst" | grep -q ':80 ' && ok "HTTP:80" || no "HTTP:80未监听"

y=$(date +%Y)
[ "$y" -ge 2026 ] && ok "时间 $(date '+%F %T')" || no "时间异常(未NTP同步)"

echo "==== 结果：通过 $OK / 异常 $NO ===="
[ "$NO" = 0 ] && echo ">>> 未发现明显问题" || echo ">>> 把上面 [!!] 行贴回来"
