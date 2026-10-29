#!/usr/bin/env bash
# =============================================================================
# 在 WSL 里本地编一版 AX1800 Pro 固件
#
# 严格镜像 .github/workflows/build.yml 里 build job 的第 5~10 步，
# 步骤名、命令、sed 全部照抄，保证「本地编出来的 == CI 编出来的」。
#
# 用法（在 WSL 的 bash 里执行）：
#   bash scripts/wsl-build.sh                  # 增量编译，已有 $WORK 会复用
#   bash scripts/wsl-build.sh --clean          # 清空 $WORK 从头来
#   bash scripts/wsl-build.sh --tmux           # 丢进 tmux 会话，关终端不中断
#   WIFI_KEY='你的密码' bash scripts/wsl-build.sh   # 覆盖 WiFi 密码（默认 12345678）
#
# 产物：$WORK/openwrt/bin/targets/qualcommax/ipq60xx/
# 日志：$WORK/logs/build-<时间戳>.log
#
# 为什么用 git clone 而不是直接拷 Windows 目录：
#   Windows 工作区里的文件是 CRLF（.gitattributes 是后加的，没重新 checkout），
#   直接拷进 WSL 会让 diy.sh 变成 "#!/bin/bash\r"，bash 报 $'\r': command not found，
#   补丁全部 malformed。git clone 会按 .gitattributes 的 eol=lf 重新铺工作树，
#   拿到的字节跟 CI 完全一致。
# =============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
TARGET="${TARGET:-qualcommax_ipq60xx}"
WORK="${WORK:-$HOME/kwrt-build}"
WIFI_KEY="${WIFI_KEY:-}"
JOBS="${JOBS:-}"
CLEAN=0
USE_TMUX=0

for a in "$@"; do
  case "$a" in
    --clean) CLEAN=1 ;;
    --tmux)  USE_TMUX=1 ;;
    -h|--help) awk 'NR>1 && /^set -/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "未知参数: $a（可用：--clean --tmux --help）" >&2; exit 2 ;;
  esac
done

REPO_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
die()    { c_red "[x] $*"; exit 1; }
step()   { echo; c_grn "===== $* ====="; }

trap 'rc=$?; [ $rc -ne 0 ] && c_red "[x] 第 $LINENO 行失败（退出码 $rc），日志：${LOG:-（尚未创建）}" >&2' ERR

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
step "0 环境检查"

[ "$(uname -s)" = Linux ] || die "这不是 Linux，请在 WSL 里跑"

if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "[+] 检测到 WSL：$(grep -o 'microsoft.*' /proc/version | head -1)"
else
  c_ylw "[!] 没检测到 WSL 标记，当成普通 Linux 继续"
fi

[ "$(id -u)" = 0 ] && die "OpenWrt 拒绝以 root 编译（会有奇怪的权限问题），请用普通用户跑，脚本内部自己 sudo"
[ -n "${SUDO_USER:-}" ] && die "检测到 SUDO_USER=$SUDO_USER，说明你是 sudo 进来的，请退出改用普通用户直接跑"

command -v sudo >/dev/null || die "没有 sudo，装不了编译依赖"
command -v git  >/dev/null || die "没有 git"

case "$WORK" in
  /mnt/*) die "WORK=$WORK 在 /mnt 下（Windows 盘，9p 文件系统）。编译会产生几十万个小文件，
         通过 9p 读写会慢 10 倍以上且 make 会因 mtime 异常误判。请用 \$HOME 下的路径" ;;
esac

ARCH="$(uname -m)"
[ "$ARCH" = x86_64 ] || die "当前架构 $ARCH，需要 x86_64（交叉编译工具链只认 x86_64 宿主）"

MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
[ "$MEM_GB" -lt 6 ] && die "WSL 只分到 ${MEM_GB}G 内存，NSS 编译至少 6G。
     在 C:\\Users\\31936\\.wslconfig 里加：
       [wsl2]
       memory=16GB
       processors=16
     然后 wsl --shutdown 重进"
echo "[+] 内存 ${MEM_GB}G / 逻辑核 $(nproc) / 架构 $ARCH"

mkdir -p "$WORK"
FREE_KB=$(df -Pk "$WORK" | awk 'NR==2{print $4}')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
[ "$FREE_KB" -lt 57671680 ] && die "$WORK 所在分区只剩 ${FREE_GB}G，至少需要 55G
     （源码 3G + build_dir/staging_dir 约 35G + 产物 1G）"
echo "[+] 可用空间 ${FREE_GB}G"

# 网络：diy.sh 要拉 6 个上游仓库 + feeds，github 不通会卡很久
echo -n "[+] 检查 github 连通性 ... "
if ! command -v curl >/dev/null 2>&1; then
  c_ylw "跳过（curl 还没装）"
elif curl -s --max-time 15 -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null \
     | grep -q '^200$'; then
  echo "OK"
else
  c_ylw "不通"
  c_ylw "    diy.sh 里有 10 多次 fetch（feeds update / git_clone_path / wget），"
  c_ylw "    github 直连不了会卡在第一步。若你有代理，先 export https_proxy=... 再跑。"
  read -r -p "    仍然继续？[y/N] " ans
  [ "${ans:-n}" = y ] || exit 1
fi

if [ "$USE_TMUX" = 1 ] && [ -z "${TMUX:-}" ]; then
  command -v tmux >/dev/null || die "没装 tmux，先 sudo apt-get install -y tmux"
  # 用环境变量传参，不拼进命令行字符串：密码里有单引号时拼接会断引号，
  # 而且会出现在 ps 和 tmux 的命令行里
  export WORK TARGET WIFI_KEY JOBS
  echo "[+] 转入 tmux 会话 kwrt，之后用 tmux attach -t kwrt 回来看进度"
  exec tmux new-session -s kwrt "bash '$0'"
fi
[ -z "${TMUX:-}" ] && c_ylw "[!] 当前不在 tmux 里。编译要 2~4 小时，关掉终端就全没了。
     建议 Ctrl-C 后用：bash scripts/wsl-build.sh --tmux"

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
mkdir -p "$WORK/logs"
LOG="$WORK/logs/build-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "[+] 日志：$LOG"
echo "[+] 工程源：$REPO_SRC"
echo "[+] 编译目录：$WORK"
echo "[+] 目标设备：$TARGET"

# ---------------------------------------------------------------------------
# 1. 依赖
# ---------------------------------------------------------------------------
step "1 安装编译依赖"

# CI 用的是 ubuntu-22.04 预装镜像，WSL 的 Ubuntu 基础镜像少几个：
# bc / time / cpio / patch / perl 这些 make 会直接用，不装会在中途才炸。
DEPS=(
  build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext
  git libncurses-dev libssl-dev python3-setuptools rsync swig unzip zip
  zlib1g-dev file wget curl dwarves llvm python3-pyelftools libpython3-dev
  aria2 jq rename libelf-dev device-tree-compiler libgmp3-dev libmpc-dev
  libfuse-dev patch bc time cpio perl subversion
  xz-utils liblzma-dev zstd pkg-config
)

sudo -E apt-get -qq update

# 整批装；只要有一个包名在当前发行版里不存在，apt 会整批失败，
# 所以失败后退化成逐个装，缺哪个就跳过哪个（并打印出来）
if ! sudo -E DEBIAN_FRONTEND=noninteractive apt-get -qq -y install "${DEPS[@]}" 2>/dev/null; then
  c_ylw "[!] 整批安装失败，逐个重试（某些包在 24.04 里改名了）"
  for p in "${DEPS[@]}"; do
    sudo -E DEBIAN_FRONTEND=noninteractive apt-get -qq -y install "$p" >/dev/null 2>&1 \
      || c_ylw "    跳过 $p（源里没有）"
  done
fi

for t in make gcc g++ python3 patch bc rsync wget curl jq git perl; do
  command -v "$t" >/dev/null || die "依赖 $t 还是没装上，先手工装一下再跑"
done
c_grn "[+] 依赖就绪"

# ---------------------------------------------------------------------------
# 2. 准备源码树
# ---------------------------------------------------------------------------
step "2 准备源码树"

if [ "$CLEAN" = 1 ] && [ -d "$WORK" ]; then
  c_ylw "[!] --clean：删除 $WORK 下除 logs 外的全部内容"
  find "$WORK" -mindepth 1 -maxdepth 1 ! -name logs -exec rm -rf {} +
fi

# 2a. 工程本体：从本地仓库 clone，让 .gitattributes 的 eol=lf 生效
case "$REPO_SRC" in
  "$WORK"/*) die "脚本是从 $WORK 里跑的，会自己 clone 自己。请在 /mnt/c 下的工程目录里跑这条脚本" ;;
esac
if [ ! -d "$WORK/src/.git" ]; then
  echo "[+] clone 工程（LF 规范化）"
  rm -rf "$WORK/src"
  git -c core.autocrlf=false clone --quiet "file://$REPO_SRC" "$WORK/src"
fi
SRC_HEAD=$(git -C "$WORK/src" rev-parse --short HEAD)
REPO_HEAD=$(git -C "$REPO_SRC" rev-parse --short HEAD 2>/dev/null || echo "?")
echo "[+] 工程 HEAD：$SRC_HEAD  $(git -C "$WORK/src" log -1 --pretty=%s)"
if [ "$SRC_HEAD" != "$REPO_HEAD" ]; then
  c_ylw "[!] 编译用的 $SRC_HEAD 与当前仓库 $REPO_HEAD 不一致（$WORK/src 是首次 clone 时钉死的）"
  c_ylw "    要编最新代码，加 --clean 重来"
fi

# diy.sh / .config 必须是 LF，否则 bash 和 patch 都会崩
if grep -qU $'\r' "$WORK/src/devices/common/diy.sh" 2>/dev/null; then
  die "clone 出来的 diy.sh 仍是 CRLF，.gitattributes 没生效。请检查 $REPO_SRC/.gitattributes"
fi
echo "[+] 行尾检查通过（LF）"

# 2b. 上游主树
if [ ! -d "$WORK/openwrt/.git" ]; then
  echo "[+] clone openwrt-25.12（--depth 1）"
  git clone --depth 1 -b openwrt-25.12 https://github.com/openwrt/openwrt "$WORK/openwrt"
fi
echo "[+] 上游 HEAD：$(git -C "$WORK/openwrt" log --oneline -1)"

# 2c. 铺 devices（顺序与 CI 一致：先 common，再设备目录，最后整个 devices/）
cp -rf "$WORK/src/devices/common/." "$WORK/openwrt/"
cp -rf "$WORK/src/devices/$TARGET/." "$WORK/openwrt/"
cp -rf "$WORK/src/devices" "$WORK/openwrt/"

# ---------------------------------------------------------------------------
# 3. diy.sh（喂 feeds、换源头、打上游补丁）
# ---------------------------------------------------------------------------
step "3 跑 devices/common/diy.sh"

cd "$WORK/openwrt"

# diy.sh 里调 git_clone_path，CI 是在同一步的 shell 里定义的。
# 这里定义并 export，函数体与 build.yml 逐字一致。
function git_clone_path() {
  trap 'rm -rf "$tmpdir"' EXIT
  branch="$1" rurl="$2" mv="$3"
  [[ "$mv" != "mv" ]] && shift 2 || shift 3
  rootdir="$PWD"
  tmpdir="$(mktemp -d)" || exit 1
  if [ ${#branch} -lt 10 ]; then
    git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$rurl" "$tmpdir"
    cd "$tmpdir"
  else
    git clone --filter=blob:none --sparse "$rurl" "$tmpdir"
    cd "$tmpdir"
    git checkout "$branch"
  fi
  if [ "$?" != 0 ]; then echo "error on $rurl"; exit 1; fi
  git sparse-checkout init --cone
  git sparse-checkout set "$@"
  [[ "$mv" != "mv" ]] && cp -rn ./* $rootdir/ || mv -n "$@"/* $rootdir/"$@"/
  cd $rootdir
}
export -f git_clone_path

chmod +x devices/common/diy.sh
# diy.sh 没有 set -e，中途某个 wget 失败不会中断（CI 也是这个行为，保持一致）
/bin/bash devices/common/diy.sh
c_grn "[+] diy.sh 跑完"

# diy.sh 之后关键文件的存在性检查：这几个缺了说明网断了，提前报，别等 make
for f in feeds/kiddin9/luci-theme-argon \
         package/network/services/uhttpd/files/uhttpd.config \
         include/version.mk; do
  [ -e "$f" ] || die "diy.sh 之后缺 $f，多半是 feeds 或 wget 没拉下来，重跑一次"
done

# ---------------------------------------------------------------------------
# 4. 组装 .config
# ---------------------------------------------------------------------------
step "4 组装 .config"

cp -f devices/common/.config .config
if [ -f "devices/$TARGET/.config" ]; then
  echo >> .config
  cat "devices/$TARGET/.config" >> .config
fi

if [ -f "devices/$TARGET/diy.sh" ]; then
  chmod +x "devices/$TARGET/diy.sh"
  /bin/bash "devices/$TARGET/diy.sh"
fi

cp -Rf ./diy/* ./ 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. 注入 WiFi 密码
# ---------------------------------------------------------------------------
step "5 注入 WiFi 密码"

WIFI_KEY="${WIFI_KEY:-12345678}"
n=${#WIFI_KEY}
if [ "$n" -lt 8 ] || [ "$n" -gt 63 ]; then
  die "WIFI_KEY 长度 $n 位，WPA2-PSK 只接受 8~63 位"
fi

python3 - "$WIFI_KEY" <<'PY'
import io, sys
key = sys.argv[1]
esc = key.replace("'", "'\\''")
p = 'package/base-files/files/etc/uci-defaults/99-ax1800'
s = io.open(p, encoding='utf-8').read()
if '__WIFI_KEY__' not in s:
    sys.exit('[x] 99-ax1800 里找不到占位符 __WIFI_KEY__')
io.open(p, 'w', encoding='utf-8').write(s.replace('__WIFI_KEY__', esc))
PY
grep -q '__WIFI_KEY__' package/base-files/files/etc/uci-defaults/99-ax1800 \
  && die "密码注入失败，占位符还在"
echo "[+] 密码已注入（${n} 位，不回显）"

# ---------------------------------------------------------------------------
# 6. 打设备补丁
# ---------------------------------------------------------------------------
step "6 打设备补丁"

cp -rn devices/common/patches "devices/$TARGET/" 2>/dev/null || true

if [ -n "$(ls -A "devices/$TARGET"/*.bin.patch 2>/dev/null)" ]; then
  git apply devices/$TARGET/patches/*.bin.patch
  echo "[+] bin.patch 已 git apply"
fi

# revert 补丁反向打，按名字排序，顺序不能乱
find "devices/$TARGET/patches" -maxdepth 1 -type f -name '*.revert.patch' -print0 \
  | sort -z | xargs -r -I % -t -0 -n 1 sh -c "patch -d './' -R --no-backup-if-mismatch -p1 -F 1 -i '%'"

find "devices/$TARGET/patches" -maxdepth 1 -type f -name '*.patch' \
     ! -name '*.revert.patch' ! -name '*.bin.patch' -print0 \
  | sort -z | xargs -r -I % -t -0 -n 1 sh -c "patch -d './' --no-backup-if-mismatch -p1 -F 1 -i '%'"

PATCH_N=$(find "devices/$TARGET/patches" -maxdepth 1 -type f -name '*.patch' ! -name '*.revert.patch' | wc -l)
echo "[+] 正向补丁 $PATCH_N 个"
# 当前基线：common 21 个 + 设备 ax6600/ly1800 2 个 = 23
[ "$PATCH_N" -ge 20 ] || c_ylw "[!] 补丁只有 $PATCH_N 个，基线是 23，检查 devices/common/patches 是不是漏拷了"
# 注意 devices/common/patches 下有 4 个 *.patch.b 和 1 个 *.patch.bak
# （china_mirrors / compressed-memory / netfilter / use_json_object_new_int64 / nginx-fancyindex），
# 后缀不是 .patch，find 匹配不到，它们从来不生效。CI 也是这个行为，此处保持一致。

# ---------------------------------------------------------------------------
# 7. defconfig + 收身
# ---------------------------------------------------------------------------
step "7 生成配置（defconfig + 收身）"

make defconfig
# 上游同款收身：无线驱动与 kmod-qca* 的 =m 全部压成 =n，由 defconfig 按依赖重解
sed -n '/# Wireless Drivers/,/# end of Wireless Drivers/p' .config | sed -e 's/=m/=n/' >> .config
sed -i "s/\(kmod-qca.*\)=m/\1=n/" .config
make defconfig

echo
echo "======== 关键项 ========"
grep -E "^CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_|^CONFIG_PACKAGE_(luci-theme-argon|luci-app-openclash|dnsmasq-full|kmod-tun|kmod-nft-tproxy|kmod-qca-nss-ecm|kmod-ath11k-ahb|wpad-mbedtls|sqm-scripts-nss)=" .config || true

echo
echo "======== iStore 自检 ========"
store_block() { awk '/config PACKAGE_luci-app-store$/ {f=1} f {print} f && /help$/ {exit}' tmp/.config-package.in; }
store_block
echo "--- 块里每个符号的取值 ---"
for s in $(store_block | grep -oE 'PACKAGE_[A-Za-z0-9_.+-]+' | sort -u); do
  v=$(grep -m1 -E "^CONFIG_${s}=" .config || true)
  [ -n "$v" ] || v="(无此行 = 符号不可见)"
  printf '  %-46s %s\n' "$s" "$v"
done

# ---------------------------------------------------------------------------
# 8. 编译前校验（与 CI 同一套断言，本地跑可以更早发现问题）
# ---------------------------------------------------------------------------
step "8 编译前校验"

fail=0
for p in luci-theme-argon luci-app-openclash dnsmasq-full kmod-tun kmod-nft-tproxy \
         kmod-nft-fullcone kmod-qca-nss-ecm kmod-ath11k-ahb wpad-mbedtls \
         luci-app-timedreboot automount luci-app-quickfile \
         luci-app-store mount-utils \
         kmod-wireguard wireguard-tools luci-proto-wireguard; do
  if ! grep -q "^CONFIG_PACKAGE_${p}=y" .config; then
    c_red "  [x] $p 没进 .config"
    fail=1
  fi
done
# 注意这里必须用 if 而不是 grep && {...}：set -e 下「没匹配到」是返回 1，
# 而「没匹配到」恰恰是期望结果，用 && 会让脚本在这里自杀
if grep -q "^CONFIG_PACKAGE_luci-app-advancedplus=y" .config; then
  c_red "  [x] advancedplus 还在，去推广没生效"; fail=1
fi
if grep -q "^CONFIG_PACKAGE_luci-app-footstrap-files=y" .config; then
  c_red "  [x] footstrap-files 还在，没摘干净"; fail=1
fi
if grep -q "^CONFIG_TARGET_ALL_PROFILES=y" .config; then
  c_red "  [x] 还在编全机型，时间会翻几倍"; fail=1
fi

if [ "$fail" != 0 ]; then
  echo
  die "编译前校验没过 —— 别急着 make，先去 .config 里查对应符号是不是「不可见」
     （判据：一行都没有 = 符号不可见/depends 没满足；'# ... is not set' = 可见但没选）"
fi
c_grn "[+] 校验通过"

# ---------------------------------------------------------------------------
# 9. 编译
# ---------------------------------------------------------------------------
step "9 编译"

if [ -z "$JOBS" ]; then
  JOBS=$(nproc)
  # 每个 cc1 峰值 1~2G，LTO 的包还要翻倍。按 2G/任务给内存留余量
  cap=$(( MEM_GB / 2 )); [ "$cap" -lt 2 ] && cap=2
  [ "$JOBS" -gt "$cap" ] && JOBS=$cap
fi
echo "[+] make -j$JOBS   （内存 ${MEM_GB}G / 逻辑核 $(nproc)）"
echo "[+] 这一步 2~4 小时，期间可以另开窗口 tail -f $LOG"
echo

date +%s > /tmp/.kwrt_t0
MK_LOG="$WORK/logs/make.log"
# 与 CI 同策略：先用默认 verbosity 跑（V=s 会让日志膨胀到几 GB 并明显拖慢），
# 失败后再用 V=s 增量重跑一次，只为拿到出错包的完整命令行。
# 用 if 包住是为了让失败不触发 set -e / ERR trap，自己接管错误处理。
if make -j"$JOBS" 2>&1 | tee "$MK_LOG"; then
  rc=0
else
  rc=${PIPESTATUS[0]}
fi

if [ "$rc" != 0 ]; then
  echo
  c_red "[x] 编译失败（退出码 $rc），用 V=s 重跑取真实报错..."
  VLOG="$WORK/logs/make-verbose.log"
  make V=s > "$VLOG" 2>&1 || true
  echo
  c_red "-------- 出错上下文（make-verbose.log 尾部）--------"
  grep -nE "Error [0-9]|error:|No rule to make target|undefined reference" "$VLOG" | tail -30 || true
  echo "-------------------------------------------------"
  tail -60 "$VLOG"
  die "完整日志：$MK_LOG 和 $VLOG"
fi
echo "[+] 编译耗时 $(( ($(date +%s) - $(cat /tmp/.kwrt_t0)) / 60 )) 分钟"

# ---------------------------------------------------------------------------
# 10. 复核产物（等同 CI 的「复核内核体积」，另加 manifest 摘要）
# ---------------------------------------------------------------------------
step "10 复核产物"

OUT="bin/targets/qualcommax/ipq60xx"
f=$(find "$OUT" -maxdepth 1 -name '*jdcloud_re-ss-01-squashfs-factory.bin' | head -1 || true)
[ -n "$f" ] || die "没找到 factory.bin，编译虽然返回 0 但产物不齐，去看 $OUT"

magic=$(od -An -tx1 -N4 "$f" | tr -d ' \n')
[ "$magic" = "d00dfeed" ] || die "factory.bin 头不是 FIT（$magic）"

fit=$(od -An -tu4 -j4 -N4 --endian=big "$f" | tr -d ' ')
lim=6291456
awk -v a="$fit" -v b="$lim" 'BEGIN{
  printf "内核 FIT: %.3f MiB / 6 MiB 分区（占用 %.1f%%，余量 %d KiB）\n", a/1048576, a*100/b, (b-a)/1024
  exit (a>b)
}' || die "内核超过 6MiB，刷进去会溢出"

sq=$(od -An -tx1 -j6291456 -N4 "$f" | tr -d ' \n')
[ "$sq" = "68737173" ] || die "6MiB 处不是 hsqs（$sq），内核/rootfs 边界异常"
c_grn "[+] 6MiB 处 hsqs 校验通过"

echo
echo "======== 产物 ========"
ls -lh "$OUT"/*jdcloud_re-ss-01* 2>/dev/null
echo
echo "======== md5 ========"
md5sum "$OUT"/*jdcloud_re-ss-01* 2>/dev/null

MAN=$(ls "$OUT"/*.manifest 2>/dev/null | head -1 || true)
if [ -n "$MAN" ]; then
  echo
  echo "======== manifest 摘要（A5 要用）========"
  echo "文件：$MAN"
  echo "包总数：$(grep -c '^Package:' "$MAN" 2>/dev/null || wc -l < "$MAN")"
  md5sum "$MAN"
else
  c_ylw "[!] 没找到 .manifest，检查 CONFIG_TARGET_PER_DEVICE_ROOTFS 或 opkg 版本"
fi

echo
c_grn "===== 全部完成 ====="
echo "产物：$WORK/openwrt/$OUT"
echo "日志：$LOG"
echo
echo "刷机：U-Boot 网页 /uimage.html 上传 *-squashfs-factory.bin，别碰 /img.html /cdt.html /art.html"
echo "刷完必验：dmesg | grep -iE 'reserved|overlap|mhi'   以及   free -h"
