# kwrt-ax1800

京东云亚瑟 AX1800 Pro（IPQ6000 / `ipq6018-jdcloud_re-ss-01`）的 Kwrt 自编固件。

- 硬件前提：**1G 运存**（1G CDT）、**2G rootfs**（扩容 GPT）、**6 MiB HLOS 内核分区**
- 基线：[kiddin9/Kwrt](https://github.com/kiddin9/Kwrt) `25.12`（官方 OpenWrt 25.12 + LibWrt 的 NSS 目标树）
- 主题：Argon 3.1.x，**页脚无外链、无作者署名**
- 编译：GitHub Actions 手动触发，约 **70–90 分钟**，成功即自动发 Release

## 开箱即用的默认值

| 项 | 值 |
|---|---|
| 管理地址 | `192.168.1.1` |
| 主机名 | `OpenWrt` |
| WiFi | 双频合一，SSID `CLI` / 密码 `12345678`（WPA2-AES） |
| WAN | DHCP（拨号需刷完进后台改一次） |
| IPv6 | LAN 侧已开（`ip6assign=60` + RA/DHCPv6 server） |
| 默认主题 | Argon |

> 密码可用 GitHub Secret `WIFI_KEY` 覆盖，不必改代码；`12345678` 只防误连，建议刷完改强密码。

## 为什么能塞进 6 MiB

Kwrt 把绝大多数 kmod 编成模块，内核里只留必需项。官方镜像 FIT 只有 **4.790 MiB**，6 MiB 分区余 **1238 KiB**。此前那版 LibWrt 自编是 5.852 MiB，只剩 151 KiB —— 开 BTF 直接构建失败。

## 这套固件有什么

| 分类 | 内容 |
|---|---|
| 代理 | OpenClash 0.48.x（含 `dnsmasq-full` 四子项 / `ruby` / `kmod-tun` / `kmod-nft-tproxy` 全套依赖） |
| VPN | WireGuard（`kmod-wireguard` + `wireguard-tools` + `luci-proto-wireguard` + `luci-lib-uqr`），内核侧是模块，不占 6 MiB |
| 网络 | `sqm-scripts-nss` + `luci-app-sqm`、`upnp`、`ddns`、`wol`、`watchcat`、`frpc`、`turboacc`（锁 NSS ECM 模式） |
| 存储 | `samba4`（U 盘共享给局域网）、`diskman`、`automount`、`block-mount`、`e2fsprogs`、`parted`、`fdisk` |
| 工具 | `ttyd`、`quickfile`、`timedreboot`、`htop`、`nano`、`iperf3`、`iStore`、`zram-swap` |

**明确不编**：Docker 全家（1G 跑不动）、`luci-app-istorerouter`、`luci-app-advancedplus`、`luci-app-footstrap-files`。

## 相对上游改了什么

### 1. 机型补丁（`devices/qualcommax_ipq60xx/diy.sh`）

| 目标 | 改动 |
|---|---|
| 无线并发 | `ipq6000-re-ss-01.dts`：`ath11k-fw-memory-mode` `<1>` → `<0>`（8 VDEV/128 peers → **16 VDEV/512 peers**） |
| NSS 无线内存 | `ipq6018-512m.dtsi`：`q6_region` `0x3700000`(55 MiB) → **`0x5500000`(85 MiB)** |
| 默认网段 | Kwrt 改成 10.0.0.1，这里改回 **192.168.1.1** |
| 主机名 | `Kwrt` → **`OpenWrt`** |
| 推广插件 | 从 `include/target.mk` 的 `DEFAULT_PACKAGES` 摘掉 `luci-app-advancedplus`、`luci-app-footstrap-files` |

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

### 4. 首次开机自动配置（`diy/.../uci-defaults/99-ax1800`）

利用 `/etc/init.d/boot` 的执行顺序（`wifi config` → kmodloader → uci-defaults），在脚本里一次性配完：

- **IPv6**：`lan.ip6assign=60`、`dhcp.lan` 的 `dhcpv6/ra=server`、`ra_flags=managed+other`
- **WiFi 双频合一**：所有 `wifi-iface` 统一 SSID/密码/`psk2`，11k + 11v 开（`ieee80211k` + `bss_transition` + `wnm_sleep_mode`），**11r 关**
- **带宽**：2.4G `HT40`，5G `HE80`（160MHz 在 IPQ6000 上干扰下反而掉速）

### 5. 与上游默认的取舍

| 项 | 上游 | 本工程 | 原因 |
|---|---|---|---|
| `CONFIG_ALL_NONSHARED` | `y` | **关** | 给 openwrt.ai 出全量 ipk 用的；个人机开着要编 897 个包 |
| `CONFIG_TARGET_ALL_PROFILES` | `y` | **关** | 上游一次编 29 个机型，这里只编一台 |
| 触发方式 | `repository_dispatch` | **`workflow_dispatch`** | 上游靠维护者 token，fork 后必须自己加手动入口 |

## 怎么用

1. 仓库 **Actions** → 左侧 `Build Kwrt · AX1800 Pro` → **Run workflow**
2. 参数保持默认（`qualcommax_ipq60xx` / 不跳过校验）
3. 约 70–90 分钟，成功后自动发 Release，含：
   - `*-squashfs-factory.bin` —— **U-Boot `/uimage.html` 刷这个**
   - `*-squashfs-sysupgrade.bin` —— 以后 LuCI 升级用
   - `*.manifest` / `md5sums.txt`

**三道校验**（都是踩坑后加的）：

- 编译前：**17 个**关键包（argon / openclash / dnsmasq-full / kmod-tun / kmod-nft-tproxy / kmod-qca-nss-ecm / kmod-ath11k-ahb / wpad-mbedtls / turboacc / store / mount-utils / kmod-wireguard …）缺任一 → 直接失败，不白等 1.5 小时
- 编译后：从成品 `factory.bin` 的 FIT 头读真实内核体积（`od -j4`），超 6 MiB 判失败。**FIT 是镜像阶段才生成的，预编阶段测不到 `itb`**
- 编译后：扫 manifest 复核推广包未混入

## 刷机

断电 → 按住 `reset` 上电 → 灯由红转蓝松手 → 浏览器 `192.168.1.1` → `/uimage.html` 上传 `factory.bin`。

**别碰** `/img.html`（刷 GPT）、`/cdt.html`、`/art.html`（WiFi 校准，写坏就废）。

刷完第一件事：**网络 → 接口 → WAN → 协议改 PPPoE**，填宽带账号。光猫桥接下 DHCP 拿不到地址，这一步不做就上不了网。拨通后 IPv6 会自动起来。

验证：

```bash
cat /proc/device-tree/model              # JDCloud RE-SS-01
uci get system.@system[0].hostname       # OpenWrt
uci get network.lan.ipaddr               # 192.168.1.1
uci get wireless.@wifi-iface[0].ssid     # CLI
lsmod | grep qca_nss | wc -l             # 20+ 个 NSS 模块
ip -6 addr show br-lan                   # 应有 240e:/2408: 公网地址
```

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

另有定时任务：**每天 03:00（北京时间）**自动跑一次。上游没变时只花一分钟（探测完就跳过），变了才进 5 小时的编译 —— 所以「上游一更新，最多隔一天就有新固件」。先探测 5 个上游源的 HEAD：

| 源 | 分支 | 决定什么 |
|---|---|---|
| `openwrt/openwrt` | `openwrt-25.12` | 主树 |
| `immortalwrt/immortalwrt` | `openwrt-25.12` | openssl / ppp / 5 个内核与 nftables 补丁 |
| `LiBwrt/openwrt-6.x` | `25.12-nss` | NSS 目标树、ath11k、mac80211（最关键） |
| `LiBwrt/LibWrt` | `25.12-nss` | image-commands.mk / Config-ipq.in / Config.in |
| `kiddin9/op-packages` | `main` | argon / openclash / turboacc 等插件 |

跟上一次成功构建的记录（`.build-state`）比对，**完全一致就跳过**，有变化才编。编译失败不发 Release，保留上一个可用版本，不会出现「自动编坏了还推给你」。

编译成功但卡在最后「发布 Release」这一步时，`publish.yml` 会通过 `workflow_run` **自动从 artifact 补发一次**（30 秒，不用重编 5 小时）；补发也失败时会把 `gh` 的原始报错写成注解，`Actions → 发布已有产物` 里能直接看到原因。

`coolsnowwolf/lede`（hack-6.12）、`qosmio/sqm-scripts-nss`、`laipeng668/nss-packages` 不参与判定 —— 影响面窄，且 lede master 每天多次提交，纳入会让「有变化」永远成立。

> GitHub 的政策：仓库连续 **60 天无活动**会自动禁用定时任务。届时手动点一次 Run workflow 即可唤醒。

## 文档

| 文件 | 内容 |
|---|---|
| [`docs/整体说明.md`](docs/整体说明.md) | 完整说明书：硬件前提 / 工程结构 / 定制清单 / 固件内容 / 编译流程 / 刷机 / 首启配置 / 已知风险 |
| [`docs/优化审计.md`](docs/优化审计.md) | 对比 GitHub 上 4 个同机型工程，列出可补的 5 个 A 级优化与不建议做的 C 级 |

## 已知风险

1. Kwrt 是 **nginx + uhttpd 双栈**（`quickfile` 用 nginx），网页打不开时两边都要查
2. opkg 源指向 `dl.openwrt.ai`，外部依赖，上游删旧目录后 `opkg update` 会 404
3. Kwrt 把 `vermagic` 强写成 `1`，方便装任意 kmod 但装错版本照样崩，认准 25.12 / ipq60xx
4. 上游 `patches/default-packages.patch` 也碰 `include/target.mk`，与去推广的 sed 相邻，上游改结构时可能冲突
5. **双频合一没有 band steering**：OpenWrt 原生只做"同名"，选频段由客户端决定。智能插座会赖在 2.4G，要强制引导需装 `usteer`
6. **turboacc 界面里别手动开 flow offloading**，任何卸载都会让部分连接绕过 OpenClash 的 TUN/TPROXY

## 许可

上游 Kwrt 与 OpenWrt 均为 GPL-2.0，本仓库继承。Argon 主题为 Apache-2.0 / MIT。
