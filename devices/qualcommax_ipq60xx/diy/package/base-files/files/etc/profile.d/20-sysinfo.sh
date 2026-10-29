#!/bin/sh
# 登录横幅的下半截：版本、内核、机型。
#
# /etc/profile 的先后来定：第 4 行 cat /etc/banner，第 47 行才按文件名顺序
# source /etc/profile.d/*.sh。所以 20- 开头能让这三行贴在那条分隔线正下方，
# 而 Kwrt 自带的 30-sysinfo.sh 紧跟着打印负载/内存/存储/IP —— 两段拼起来是一整块。
#
# 只补 30-sysinfo.sh 没有的三项。内存、存储、IP 它已经打了，这里再来一遍
# 就是同一个数字在屏幕上出现两次，纯噪音。
#
# 只在真正登录时打印：stdout 必须是终端，且 SHLVL=1。
# su -、screen/tmux 新开窗口里不会每开一次就刷一遍。
#
# 每行不超过 25 列，与 banner 里那条 25 格分隔线等宽。

[ -t 1 ] || return 0 2>/dev/null

if [ "${SHLVL:-1}" -gt 1 ]; then
	return 0 2>/dev/null || exit 0
fi

# 用 ID + RELEASE，不用 DESCRIPTION：后者在 Kwrt 上带着构建日期
# （"OpenWrt 25.12-SNAPSHOT 10.29.2026"），一行就顶破分隔线宽度。
# 放在子 shell 里读，免得 DISTRIB_ARCH 之类的变量留在用户的登录环境里。
_ver=$(. /etc/openwrt_release 2>/dev/null; printf '%s %s' "${DISTRIB_ID:-OpenWrt}" "${DISTRIB_RELEASE:-}")
_krn=$(uname -r)
_model=$(cat /tmp/sysinfo/model 2>/dev/null)

# 不缩进：Kwrt 自带的 30-sysinfo.sh 是顶着左边打印的，两段共用同一个左边缘
printf '%s\n' "${_ver% }"
printf 'kernel %s\n' "${_krn:-?}"
printf '%s\n' "${_model:-OpenWrt}"

unset _ver _krn _model
