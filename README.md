# kwrt-ax1800

京东云亚瑟 AX1800 Pro（IPQ6000 / `ipq6018-jdcloud_re-ss-01`）的 Kwrt 自编固件。

- 硬件前提：**1G 运存**（1G CDT）、**2G rootfs**（扩容 GPT）、**6 MiB HLOS 内核分区**
- 基线：[kiddin9/Kwrt](https://github.com/kiddin9/Kwrt) `25.12`（官方 OpenWrt 25.12 + LibWrt 的 NSS 目标树）
- 主题：Argon 3.1.x，**页脚无外链、无作者署名**
- 编译：GitHub Actions **每天 03:00 探测上游**，有变化才全量编（约 **2.5–3 小时**，实测 163 分钟），也可手动 dispatch；成功即自动发 Release
- 软件源：7 条全在 `dl.openwrt.ai`，与固件**同源同版本**（`aarch64_cortex-a53` / 内核 `6.12.112`），约 1.1 万个包，`kmod` 可直接 `opkg install`（细节与坑见文末「已知风险」第 2 条）

## 开箱即用的默认值

| 项 | 值 |
|---|---|
| 管理地址 | `192.168.1.1` |
| 主机名 | `OpenWrt` |
| WiFi | 双频合一，SSID `CLI` / 密码 `12345678`（WPA2-AES） |
| 后台账号 | `root`，密码由 Secret `ROOT_PASSWORD` 决定；**没配就留空**，首次登录会提示设置 |
| WAN | DHCP（拨号需刷完进后台改一次） |
| IPv6 | LAN 侧已开（`ip6assign=60` + RA/DHCPv6 server） |
| 默认主题 | Argon |

> WiFi 密码可用 GitHub Secret `WIFI_KEY` 覆盖，后台密码用 `ROOT_PASSWORD`，都不必改代码。`12345678` 只防误连，建议刷完改强密码。
>
> 后台密码特意**没有**写死成 `root`（Kwrt 上游就是 `root/root`，等于把密码印在固件里）。仓库里只有 `__ROOT_PASSWORD__` 占位符，构建设置里配了 Secret 就注入，没配就留空。

## 为什么能塞进 6 MiB

Kwrt 把绝大多数 kmod 编成模块，内核里只留必需项。官方镜像 FIT 只有 **4.790 MiB**，6 MiB 分区余 **1238 KiB**。此前那版 LibWrt 自编是 5.852 MiB，只剩 151 KiB —— 开 BTF 直接构建失败。

## 这套固件有什么

| 分类 | 内容 |
|---|---|
| 代理 | OpenClash 0.48.x（含 `dnsmasq-full` 四子项 / `ruby` / `kmod-tun` / `kmod-nft-tproxy` 全套依赖） |
| VPN | WireGuard（`kmod-wireguard` + `wireguard-tools` + `luci-proto-wireguard` + `luci-lib-uqr`），内核侧是模块，不占 6 MiB |
| 网络 | `sqm-scripts-nss` + `luci-app-sqm`、`upnp`、`ddns`、`wol`；硬件加速走 NSS ECM，BBR 走 `kmod-tcp-bbr`，全锥 NAT 走 `kmod-nft-fullcone`（原生 FULLCONENAT，非 turboacc） |
| 存储 | `samba4`（U 盘共享给局域网）、`diskman`、`automount`、`block-mount`、`e2fsprogs`、`parted`、`fdisk` |
| 工具 | `ttyd`、`quickfile`、`timedreboot`、`htop`、`nano`、`iperf3`、`iStore`、`zram-swap` |

**明确不编**：Docker 全家（1G 跑不动）、`luci-app-istorerouter`、`luci-app-advancedplus`、`luci-app-footstrap-files`、`luci-app-package-manager`（**摘不掉**，`luci-nginx` 硬依赖；改成挪到「系统 → 软件包」）、`luci-app-watchcat`、`luci-app-frpc`。

## 相对上游改了什么

### 1. 机型补丁（`devices/qualcommax_ipq60xx/diy.sh`）

| 目标 | 改动 |
|---|---|
| 无线并发 | `ipq6000-re-ss-01.dts`：`ath11k-fw-memory-mode` `<1>` → `<0>`（8 VDEV/128 peers → **16 VDEV/512 peers**） |
| NSS 无线内存 | `ipq6018-512m.dtsi`：`q6_region` `0x3700000`(55 MiB) → **`0x5500000`(85 MiB)** |
| 默认网段 | Kwrt 改成 10.0.0.1，这里改回 **192.168.1.1** |
| 主机名 | `Kwrt` → **`OpenWrt`** |
| 推广插件 | 从 `include/target.mk` 的 `DEFAULT_PACKAGES` 摘掉 `luci-app-advancedplus`、`luci-app-footstrap-files`、`luci-app-package-manager` |

每条都带 `grep -q` 前置校验，上游改写法就 `exit 1`，不会静默编出一个"看起来正常"的固件。

### 2. 品牌串整体回 OpenWrt

上游 `common/diy.sh` 有一条 `s/OpenWrt/Kwrt/g`，扫了 7 个文件。这里整批反向替换：主机名、默认 SSID、镜像名前缀、`VERSION_DIST`、menu 标题、U-Boot 版本串全回 **OpenWrt**。

### 3. 去外链 / 去广告

| 位置 | 处理 |
|---|---|
| `argon/.../footer.ut`、`footer_login.ut` | 3 条外链（LuCI 仓库、jerrykuku、`version.disturl`=openwrt.ai）全删，只留纯文本 `LuCI · Argon 3.1.x` |
| `/etc/banner` | 自绘 Q 版小猫 ASCII（原版是 Kwrt 那只 + `by Kiddin'`） |
| `/etc/os-release` | 去掉 ` by Kiddin'`（符号链接，必须 `sed --follow-symlinks`） |
| `CONFIG_VERSION_HOME_URL` | 由 `https://openwrt.ai/` 改成本仓库地址 |
| 概览页 | Kwrt 的 `08_stats.js`（带宽卡）和改过的 `index.js` 全换回上游原版，见 3.1 |

### 3.1 概览页与菜单

Kwrt 的 `feeds/kiddin9/luci-mod-status` 和上游差得比想象多：`index.js` 被改成带 30 秒
`sessionStorage` 缓存的懒加载版，`include/` 目录也不同（`26_ports` 代替 `29_ports`、多一个
`11_cpu`、没有 `50_dsl`、`40_dhcp`/`60_wifi` 是重写过的胖版本）。只替换单个文件会出现
两张端口卡、多一张 CPU 卡，而且缓存会让官方模块的按钮 30 秒内点了没反应。

现在的做法是**整套对齐上游** `immortalwrt/luci@openwrt-25.12`：

| 文件 | 处理 |
|---|---|
| `view/status/index.js` | 换成官方版，恢复官方轮询语义 |
| `10/20/25/29/30/40/50/60_*.js` | 官方原文件 |
| `08_stats.js`（带宽） | 空壳，`render()` 返回 `null` → 卡片永久隐藏 |
| `11_cpu.js`、`26_ports.js` | 同上，摘掉 Kwrt 独有的卡 |

原理：官方 `index.js` 只有 `render()` 返回非 `null` 时才把卡片 `display` 设回 `''`，
返回 `null` 或 `load()` 抛错的卡片会一直保持 `display:none`，不用改任何上游代码。

菜单上其实**摘不掉** `luci-app-package-manager`——`luci-nginx` 和 `luci` 两个包的 `Depends`
里都硬写着它，从 `DEFAULT_PACKAGES` 删、`.config` 里 `is not set` 都压不住，`defconfig`
会按依赖关系把它重新选上（2026-10-30 实机确认）。所以改成 coexistence：

| 位置 | 内容 | 做法 |
|---|---|---|
| 左侧顶级 `iStore`（order 30） | 覆写 `store.lua` 的 4 行：路径 `admin/services/store` → `admin/package-manager`，标题 `_("Software")` → `iStore` | 本仓库 `diy/feeds/kiddin9/luci-app-store/` |
| `系统 → 软件包` | 官方包管理页 | 覆写它的 `menu.d/luci-app-package-manager.json`，路径改成 `admin/system/package-manager` |
| iStore 页内“更多插件请使用软件包” | 指向新的系统路径 | 覆写 `store/main.htm` 那一行 |

三份覆盖少任何一份都会出问题：少第一份菜单还叫软件包；少第二份两份抢同一路径把 iStore 顶掉；
少第三份点进去原地打转。构建里加了断言，`cp -Rf ./diy/*` 静默失败时会直接红。
`{"admin","store",...}` 那些 AJAX 端点刻意不动，否则页面内的请求会全部 404。

### 4. 首次开机自动配置（`diy/.../uci-defaults/99-ax1800`）

首启时一次性配完：

- **IPv6**：`lan.ip6assign=60`、`dhcp.lan` 的 `dhcpv6/ra=server`、`ra_flags=managed+other`
- **WiFi 双频合一**：所有 `wifi-iface` 统一 SSID/密码/`psk2`，11k + 11v 开（`ieee80211k` + `bss_transition` + `wnm_sleep_mode`），**11r 关**
- **带宽**：2.4G `HT40`，5G `HE80`（160MHz 在 IPQ6000 上干扰下反而掉速）
- **WiFi 校准（cal）**：开机早期从本机 eMMC 的 `0:ART` 分区（`mmcblk0p15`，偏移 `0x1000`）切出 64 KiB。每台机器的校准数据不同，**不进仓库、不进镜像**。真正保证它「在驱动要之前就在位」的是 `caldata-early`，见 4.2

⚠️ **首次开机无线不是秒出**：ath11k 注册 phy 要跑完 QMI 初始化。首启脚本对无线走快/慢双路径——phy 没好就后台等（最长 180 秒）再补配置并 `wifi reload`。
在 phy 出现之前看 `iw dev` 是空的、LuCI 没有无线，都正常。排查看 `logread | grep ax1800-wifi`。
（build-13 实测要 4 分半且无线全无，根因是 cal 与 NSS 固件都晚于驱动请求，见 4.2；修完这条后应恢复到几十秒量级。）

### 4.1 安全默认值（覆盖 Kwrt 的 `my-default-settings`）

Kwrt 的 `99-default-settings` 会在首启时写一批"方便推广机"的设置。这里整份覆盖，只动 6 行：

| 项 | Kwrt | 本工程 | 原因 |
|---|---|---|---|
| root 密码 | `root/root` 写死 | Secret `ROOT_PASSWORD` 注入，缺省留空 | 写死等于把密码印在固件里 |
| `flow_offloading` / `_hw` | `1` / `1` | `0` / `0` | 软件卸载与 SQM/QoS 打架；真加速走 NSS ECM |
| `dns_redirect` | `1` | `0` | 不再劫持 53 端口，内网自建 DNS 能用 |
| `localservice` | `0` | `1` | dnsmasq 只监听本地 |
| `rebind_protection` | `0` | `1` | 恢复 DNS 重绑定保护 |
| `hostname` 兜底 | `Kwrt` | `OpenWrt` | 与品牌一致 |

覆盖文件头部有 `★` 清单，上游一改这份就要重新对一遍。

### 4.2 开机早期的两支 init 脚本（`nss-fw-early` / `caldata-early`）

build-13 的实测首启：`qca-nss` probe `-110`、`qmi failed to load CAL data file`、`/sys/class/ieee80211` 空、开机 **4 分半**且无线全无。

根因不是「固件包没编进去」（对比 `.manifest`，`nss-firmware-ipq60xx`、`ath11k-firmware-ipq6018` 都在），而是**固件晚于驱动的请求**：

- `request_firmware()` 只在开头**同步查一次**文件系统。查不到就切用户态回落，等 `/sys/class/firmware/<name>/data`，满 `firmware_loading_timeout`（默认 60 秒）返回 `-110`。**回落窗口里再往 `/lib/firmware` 新建文件不算数**——这是"必须开工前备好"的硬约束。
- NSS 是**名字对不上**：包只装 `qca-nss0-retail.bin`，驱动要 `qca-nss0.bin`，上游靠 `10-qca-nss-fw` 热插拔事后 `ln -s`。
- cal 同理：`11-ath11k-caldata` 走 `caldata_extract_mmc` → 直接 `dd` 到 `/lib/firmware`，也是事后补。
- `kmodloader` 又是串行 `insmod`：NSS 先卡满 60 秒，ath11k 被推到 147 秒才起 QMI，再等 60 秒 → 两条链级联。

两支脚本都挂在 `preinit` 的 START 段，早于 `kmodloader`：

| 脚本 | START | 做什么 | 幂等性 |
|---|---|---|---|
| `nss-fw-early` | 08 | 建 `qca-nss0.bin → qca-nss0-retail.bin` 软链（失败退化为复制）；把固件等待超时 60s → **10s** | 已存在则跳过；只认 `jdcloud` 机型 |
| `caldata-early` | 09 | 从 `mmcblk0p15` 偏移 `0x1000` 切 64 KiB 到 `/lib/firmware/ath11k/IPQ6018/hw1.0/`，先写 `.tmp` 再 `mv` | 已存在则跳过；只认 `jdcloud` 机型 |

把超时收到 10 秒是纯兜底：真出意外也只耽误 10 秒，不会再把后面的模块一起拖慢。
两支脚本的执行位由 `99-ax1800` 再 `chmod +x` 一次（`cp -Rf ./diy/*` 受 umask 影响会丢执行位，一丢就静默不 enable）。

### 4.3 LuCI 全站 500：一个漏写的依赖

开机后访问任何页面都 500，报 `module 'luci.netstat' not found`。根因不在官方 LuCI，而在 `kiddin9/op-packages` 的同名覆盖包 `luci-mod-status`：它自带 `controller/netstat.lua`（第 5 行 `require("luci.netstat")`），却没把 `luci-app-netstat` 写进 `LUCI_DEPENDS`。而 dispatcher 建菜单要遍历**所有** controller，一个坏就全站白屏——所以不是"某页打不开"，是彻底进不去。

走装包这条路不通：`luci-app-netstat` 会拖进 `vnstat2` 守护进程和 `luci-compat`，为一个 40 行的 lua 库不值。现在的做法是把那个模块原样收进 `base-files/files/usr/lib/lua/luci/netstat.lua`（只补库、不装前端），它 `require` 的 `luci.jsonc` 由 `.config` 显式补 `luci-lib-jsonc=y`，不赌传递依赖。

> 为什么一定要覆盖而不是绕开：kiddin9 feed 在 `feeds.conf` 最后、`feeds install -a` 最后落地，同名包必然替代官方包。这个文件是 2026-10-05 上游 Sync 时进来的，所以 build-11、build-13 都中，不是哪次改动改坏的。

### 5. 与上游默认的取舍

| 项 | 上游 | 本工程 | 原因 |
|---|---|---|---|
| `CONFIG_ALL_NONSHARED` | `y` | **关** | 给 openwrt.ai 出全量 ipk 用的；个人机开着要多编上千个包 |
| `CONFIG_TARGET_ALL_PROFILES` | `y` | **关** | 上游一次编 29 个机型，这里只编一台 |
| 触发方式 | `repository_dispatch` | **`workflow_dispatch`** | 上游靠维护者 token，fork 后必须自己加手动入口 |

## 怎么用

1. 仓库 **Actions** → 左侧 `Build Kwrt · AX1800 Pro` → **Run workflow**
2. 参数保持默认（`qualcommax_ipq60xx` / 不跳过校验）
3. 约 **2.5–3 小时**（build-13 实测 163 分钟），成功后自动发 Release，含：
   - `*-squashfs-factory.bin` —— **U-Boot `/uimage.html` 刷这个**
   - `*-squashfs-sysupgrade.bin` —— 以后 LuCI 升级用
   - `*.manifest` / `md5sums.txt`

**四道校验**（都是踩坑后加的）：

- **编译前**：**18 个**关键包（argon / openclash / dnsmasq-full / kmod-tun / kmod-nft-tproxy / kmod-nft-fullcone / kmod-qca-nss-ecm / kmod-ath11k-ahb / wpad-mbedtls / store / luci-lib-jsonc / mount-utils / kmod-wireguard …）缺任一 → 直接失败，不白等 3 小时
- **编译前**：三个「必须不存在」的反向断言——`luci-app-advancedplus`、`luci-app-footstrap-files`、`TARGET_ALL_PROFILES`，出现即失败（去推广和单机型裁剪有没有真生效）
- **编译后**：从成品 `factory.bin` 的 FIT 头读真实内核体积（`od -j4`），超 6 MiB 判失败。**FIT 是镜像阶段才生成的，预编阶段测不到 `itb`**
- **编译后**：扫 manifest 复核推广包未混入

**开机后**：`self-check.sh` 还会扫所有 LuCI controller 的 `require("luci.*")`，逐个核对模块文件是否存在——netstat 那类「controller 在、模块不在」的 500 问题开机即暴露，不用等打开网页。

## 刷机

断电 → 按住 `reset` 上电 → 灯由红转蓝松手 → 浏览器 `192.168.1.1` → `/uimage.html` 上传 `factory.bin`。

**别碰** `/img.html`（刷 GPT）、`/cdt.html`、`/art.html`（WiFi 校准，写坏就废）。

> 动手前先确认自己有一份**含 ART 的备份**。这块分区是整机上唯一单份、不可重建的
> （里面是每台机器出厂时跑射频测试写进去的校准值和 MAC，网上没有能直接用的通用备份），
> 写坏了这台机器的无线就永久没了。**整块备，别只切 64 KiB**：
>
> ```bash
> N=$(cat /sys/class/block/mmcblk0p15/size)
> dd if=/dev/mmcblk0p15 of=/root/backup/art.bin bs=512 count=$N
> md5sum /root/backup/art.bin
> ```
>
> 已有的备份（整盘 `dd if=/dev/mmcblk0` 或单分区都行）在电脑上跑
> `python scripts/art-backup.py 备份文件` 即可验证里面有没有 ART、是不是空的、有没有被截断，
> 用法与恢复流程见 [`docs/整体说明.md` 5.7](docs/整体说明.md)。
> 4.2 的 `caldata-early` 每次开机都从这块分区重新切，分区本身永远只读、不会被它改动。

刷完第一件事：**网络 → 接口 → WAN → 协议改 PPPoE**，填宽带账号。光猫桥接下 DHCP 拿不到地址，这一步不做就上不了网。拨通后 IPv6 会自动起来。

验证（**开机满 2~3 分钟后**再跑）：

```bash
uclient-fetch -O - https://raw.githubusercontent.com/Living877/kwrt-ax1800/main/scripts/self-check.sh | sh
```

结尾打印 `通过 X / 异常 Y`，覆盖机型/密码/DNS 安全三项/BBR/全锥 NAT/NSS/无线/存储/菜单/监听/时间。
WAN 未通拉不下来时，从电脑 `scp scripts/self-check.sh root@192.168.1.1:/tmp/` 再执行；
**不要整段粘贴脚本**（多行 `if/else` 经终端折行后判定会坏）。

手工抽查：

```bash
cat /proc/device-tree/model              # JDCloud RE-SS-01
uci get system.@system[0].hostname       # OpenWrt
uci get network.lan.ipaddr               # 192.168.1.1
uci get wireless.@wifi-iface[0].ssid     # CLI
lsmod | grep qca_nss | wc -l             # 20+ 个 NSS 模块
ip -6 addr show br-lan                   # 应有 240e:/2408: 公网地址
```

> 内存显示约 878 MiB 而非 1 GiB 是正常的（Q6 保留区 85 MiB + TZ/NSS + 内核）。
> eMMC 上 `p19`(5G) / `p20`(7.4G) 两块空闲分区**保持现状不合并**：rootfs 已 2 GB、仅用 5%，
> 改 GPT 有变砖风险，不值得。风扇若是带物理开关的独立温控器（45℃ 开 / 40℃ 关），固件不负责它。

跑 OpenClash 前建议关掉硬件卸载，否则部分流量不走代理：

```bash
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall
/etc/init.d/qca-nss-ecm disable
/etc/init.d/firewall restart
```

## 升级

### 在线升级（保留配置）

Release 除了带版本号的长文件名，还固定附一份 `sysupgrade.bin` / `factory.bin`，所以 `releases/latest/download/` 永远指向最新版，不用去翻页面找文件名。SSH 两条命令：

```bash
wget -O /tmp/fw.bin https://github.com/Living877/kwrt-ax1800/releases/latest/download/sysupgrade.bin
sysupgrade /tmp/fw.bin          # 保留配置；加 -n 则清空配置
```

也可以走界面：**系统 → 备份/刷写固件**，上传 `sysupgrade.bin`，勾「保留配置」。

⚠️ **别装 `owut` / `luci-app-attendedsysupgrade`**。ASU 服务器用它自己的 imagebuilder 按包列表重建，我们的源码级定制（q6 85 MiB、NSS 内核模块、banner、品牌串、首启脚本、页脚覆盖）**全部会丢**；而且 `kmod-qca-nss-ecm`、`kmod-ath11k-ahb` 官方源里没有，构建大概率直接失败。这包在这个固件上是陷阱，故意没装。

刷新版时**保留配置**意味着首启脚本不再执行（`/etc/config/wireless` 已存在），SSID/密码/IPv6 设置原样延续。想让新的 `WIFI_KEY` 生效，得 `sysupgrade -n` 清一次配置。

### 自动跟上游

上游源码全部 `--depth 1` 现拉、不 pin 版本，**手动点 Run workflow 拿到的永远是当天最新**，不存在落后。

另有定时任务：**每天 03:00（北京时间）**自动跑一次。上游没变时只花一分钟（探测完就跳过），变了才进 3 小时的编译 —— 所以「上游一更新，最多隔一天就有新固件」。先探测 5 个上游源的 HEAD：

| 源 | 分支 | 决定什么 |
|---|---|---|
| `openwrt/openwrt` | `openwrt-25.12` | 主树 |
| `immortalwrt/immortalwrt` | `openwrt-25.12` | openssl / ppp / 5 个内核与 nftables 补丁 |
| `LiBwrt/openwrt-6.x` | `25.12-nss` | NSS 目标树、ath11k、mac80211（最关键）。仓库已改名 `LiBwrt/LibWrt`，旧名 301 仍通 |
| `LiBwrt/LibWrt` | `25.12-nss` | image-commands.mk / Config-ipq.in / Config.in |
| `kiddin9/op-packages` | `main` | argon / openclash / fullconenat-nft 等插件（原 turboacc 已删） |

跟上一次成功构建的记录（`.build-state`）比对，**完全一致就跳过**，有变化才编。编译失败不发 Release，保留上一个可用版本，不会出现「自动编坏了还推给你」。

编译成功但卡在最后「发布 Release」这一步时，`publish.yml` 会通过 `workflow_run` **自动从 artifact 补发一次**（30 秒，不用重编 3 小时）；补发也失败时会把 `gh` 的原始报错写成注解，`Actions → 发布已有产物` 里能直接看到原因。

> 这条保险本身也坏过很久：`publish.yml` 第 61 行的 shell 注释里写了个空的 `${{ }}`，GitHub 在**解析阶段**就判文件无效——27 次运行全是秒挂、`jobs` 为空、从未补发过一次。已修，且现在 workflow 的任何改动都要先过 `actionlint`。

`coolsnowwolf/lede`（hack-6.12）、`qosmio/sqm-scripts-nss`、`laipeng668/nss-packages` 不参与判定 —— 影响面窄，且 lede master 每天多次提交，纳入会让「有变化」永远成立。

> GitHub 的政策：仓库连续 **60 天无活动**会自动禁用定时任务。届时手动点一次 Run workflow 即可唤醒。

## 文档

| 文件 | 内容 |
|---|---|
| [`docs/整体说明.md`](docs/整体说明.md) | 完整说明书：硬件前提 / 工程结构 / 定制清单 / 固件内容 / 编译流程 / 刷机 / 首启配置 / 已知风险（含软件源实测） |
| [`docs/上游对比诊断.md`](docs/上游对比诊断.md) | LuCI 500 / NSS 固件名 / cal 提取三个 bug 的溯源：逐条贴上游原文，说明为什么官方树不中、Kwrt 缝合后必中、社区靠重启掩盖 |
| [`docs/优化审计.md`](docs/优化审计.md) | 对比 GitHub 上 4 个同机型工程，列出可补的 5 个 A 级优化与不建议做的 C 级 |
| [`docs/固件验收清单.md`](docs/固件验收清单.md) | 刷完怎么验：首启即验 / 功能 / 性能 / 稳定性，标注哪些能一键、哪些必须人肉 |

脚本：`scripts/self-check.sh`（固件一键自检）、`scripts/wifi-diag.sh`（无线专项排障）、
`scripts/art-backup.py`（在电脑上校验备份里的 ART，见 5.7）。

## 已知风险

1. Kwrt 是 **nginx + uhttpd 双栈**（`quickfile` 用 nginx），网页打不开时两边都要查
2. **软件源是 7 条，全指向 `dl.openwrt.ai`，没有备用源**（core / base / packages / luci / routing / video / kiddin9，共约 1.1 万个包）。core 的路径带内核版本号——`targets/qualcommax/ipq60xx/6.12.112`——上游一升内核这个目录就换、旧的会被清，届时所有 kmod 装不上（base/luci/packages 仍可用）。真遇到就改那一行的版本号再 `opkg update`。旧域名 `op.supes.top` 已死，`99-default-settings` 里那句 `sed` 现在是空操作
3. Kwrt 把 `vermagic` 强写成 `1`，方便装任意 kmod 但装错版本照样崩，认准 25.12 / ipq60xx
4. 上游 `patches/default-packages.patch` 也碰 `include/target.mk`，与去推广的 sed 相邻，上游改结构时可能冲突
5. **双频合一没有 band steering**：OpenWrt 原生只做"同名"，选频段由客户端决定。智能插座会赖在 2.4G，要强制引导需装 `usteer`
6. **别手动开 flow offloading**（防火墙 → 常规设置里的软件/硬件流量分载），任何卸载都会让部分连接绕过 OpenClash 的 TUN/TPROXY；全锥 NAT 与它无关，可以放心开
7. **4.2 那两支 init 脚本目前只过了静态验证，还没上真机**：build-13 的 `-110` 是在修复前的镜像上抓的。刷完 build-17 第一件事就是看 `ls /sys/class/ieee80211/`（应有 phy）和 `dmesg | grep -iE 'qca-nss|ath11k' | head`（不该再有 `-110`）

## 许可

上游 Kwrt 与 OpenWrt 均为 GPL-2.0，本仓库继承。Argon 主题为 Apache-2.0 / MIT。
