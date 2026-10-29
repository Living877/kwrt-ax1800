#!/bin/sh
# 登录信息的下半截。
#
# /etc/profile 的顺序是「先 cat /etc/banner，再 source /etc/profile.d/*.sh」，
# 所以这几行会紧贴在 banner 那条分隔线下面，看起来是一整块横幅。
# 版本、内核、内存这些值每天构建都可能变，静态 banner 里写死会过期，只能现取。
#
# 只在真正登录时打印：stdout 必须是终端，且 SHLVL=1。
# 这样 su -、screen/tmux 新开窗口里不会每开一次就刷一遍。
#
# 每行控制在 22 列以内，与 banner 里那条分隔线等宽。

[ -t 1 ] || return 0 2>/dev/null

if [ "${SHLVL:-1}" -gt 1 ]; then
	return 0 2>/dev/null || exit 0
fi

# /etc/openwrt_release 里是 DISTRIB_DESCRIPTION='OpenWrt 25.12'，用子 shell 读，
# 免得这些变量（还有 DISTRIB_ARCH 之类）留在用户的登录环境里
_ver=$(. /etc/openwrt_release 2>/dev/null; printf '%s' "${DISTRIB_DESCRIPTION:-OpenWrt}")
_krn=$(uname -r)
_model=$(cat /tmp/sysinfo/model 2>/dev/null)
_ram=$(awk '/^MemTotal:/ { printf "%dM", $2 / 1024 }' /proc/meminfo 2>/dev/null)
_disk=$(df -h / 2>/dev/null | awk 'NR == 2 { print $2 }')
_ip=$(uci -q get network.lan.ipaddr 2>/dev/null)

printf '  %s\n' "$_ver"
printf '  kernel %s\n' "${_krn:-?}"
printf '  %s\n' "${_model:-OpenWrt}"
printf '  RAM %s  DISK %s\n' "${_ram:-?}" "${_disk:-?}"
[ -n "$_ip" ] && printf '  LAN %s\n' "$_ip"

unset _ver _krn _model _ram _disk _ip
