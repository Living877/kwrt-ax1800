# kwrt-ax1800

京东云亚瑟 AX1800 Pro（IPQ6000 / `jdcloud_re-ss-01`）的 Kwrt 自编工程。

- 硬改档案：**1G 运存**（1G CDT）、**2G rootfs**（扩容 GPT）、**6 MiB HLOS 内核分区**
- 基础：[kiddin9/Kwrt](https://github.com/kiddin9/Kwrt) `25.12` 分支（官方 OpenWrt 25.12 + LibWrt 的 NSS 目标树）
- 主题：Argon 3.1.x，**页脚外链与作者署名已移除**
- 编译：GitHub Actions 手动触发，产物自动发 Release

## 为什么能塞进 6 MiB

Kwrt 把绝大多数 kmod 编成模块，内核里只留必需项，官方镜像的 FIT 只有 **4.790 MiB**，6 MiB 分区还余 1.2 MB。这也是选它而不是继续堆内核的原因——此前那版 LibWrt 内核 5.852 MiB，只剩 151 KiB 余量。

## 相对上游改了什么

### 1. 机型补丁（`devices/qualcommax_ipq60xx/diy.sh` 末尾）

| 目标 | 改动 |
|---|---|
| 无线并发能力 | `ipq6000-re-ss-01.dts`：`ath11k-fw-memory-mode` `<1>` → `<0>`（8 VDEV/128 peers → **16 VDEV/512 peers**） |
| NSS 无线内存 | `ipq6018-512m.dtsi`：`q6_region` `0x3700000`(55MiB) → **`0x5500000`(85MiB)** |
| 默认网段 | Kwrt 改成 10.0.0.1，这里改回 **192.168.1.1** |
| 主机名 | `Kwrt` → **`Arthur`** |
| 推广插件 | 从 `include/target.mk` 的 `DEFAULT_PACKAGES` 摘掉 `luci-app-advancedplus` |

每条补丁都带 `grep -q` 前置校验，匹配不上直接 `exit 1`，不会静默编出一个"看起来正常"的固件。

### 2. 去外链 / 去广告

| 位置 | 处理 |
|---|---|
| `argon/.../footer.ut` | 原文件 3 个外链（LuCI 仓库、jerrykuku 作者仓库、`version.disturl`=openwrt.ai）全部删除，只留一行纯文本 `LuCI · Argon 3.1.x` |
| `argon/.../footer_login.ut` | 同上，登录页页脚同样处理 |
| `/etc/banner` | 换成无品牌版（原版带 `by Kiddin'`） |
| `CONFIG_VERSION_HOME_URL` | 由 `https://openwrt.ai/` 改成本仓库地址 |
| `luci-app-advancedplus` | 不编入（Kwrt 的"进阶设置"入口，推广载体） |
| `luci-app-store`（iStore） | 不编入（首页带推荐位） |

已确认**本来就没有**外链、无需处理：`sysauth.ut`（登录 logo 只链 `/`）、`30-sysinfo.sh`（SSH 状态屏）、`advanced.htm`。

### 3. 与上游默认的取舍

| 项 | 上游 | 本工程 | 原因 |
|---|---|---|---|
| `CONFIG_ALL_NONSHARED` | `y` | **关** | 那是给 openwrt.ai 出全量 ipk 仓库用的；个人机开着要编 897 个包，4 核 6–10 小时且易爆盘 |
| `CONFIG_TARGET_ALL_PROFILES` | `y` | **关** | 上游一次编 29 个机型；这里只编 `jdcloud_re-ss-01` |
| 触发方式 | `repository_dispatch` | **`workflow_dispatch`** | 上游靠维护者 token 触发，fork 后必须自己加手动入口 |

## 怎么用

1. 仓库 **Actions** → 左侧 `Build Kwrt · AX1800 Pro` → **Run workflow**
2. 参数保持默认即可（`qualcommax_ipq60xx` / 内建 OpenClash / 不跳过校验）
3. 约 2–3 小时，成功后自动生成 Release，里面有：
   - `*-squashfs-factory.bin` —— **U-Boot 网页 `/uimage.html` 刷这个**
   - `*-squashfs-sysupgrade.bin` —— 以后 LuCI 升级用
   - `*.manifest` / `md5sums.txt`

编译前会先卡一道校验：关键包（argon / openclash / dnsmasq-full / kmod-tun / kmod-qca-nss-ecm / kmod-ath11k-ahb / wpad-mbedtls）只要有一个没进 `.config` 就直接失败，不会白等两小时。

编完还会从成品 `factory.bin` 的 FIT 头读真实内核体积，超过 6 MiB 直接判失败。

## 刷机

断电 → 按住 reset 上电 → 灯由红转蓝松手 → 浏览器 `192.168.1.1` → `/uimage.html` 上传 factory.bin。

**别碰** `/img.html`（刷 GPT）、`/cdt.html`、`/art.html`（WiFi 校准，写坏就废）。

刷完先验这几条：

```bash
cat /proc/device-tree/model                    # JDCloud RE-SS-01
uci get system.@system[0].hostname             # Arthur
uci get network.lan.ipaddr                     # 192.168.1.1
dmesg | grep -i "memory:"                      # 1G 的迹象
lsmod | grep qca_nss | wc -l                   # 20+ 个 NSS 模块
iwinfo                                         # 2.4G + 5G 两个 radio
```

跑 OpenClash 之前把 NSS 硬卸载关掉，否则部分流量不走代理：

```bash
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall
/etc/init.d/qca-nss-ecm disable
/etc/init.d/firewall restart
```

## 已知风险

1. Kwrt 是 **nginx + uhttpd 双栈**，排错时别只盯 uhttpd
2. 固件内 opkg 源指向 `dl.openwrt.ai`，保留它才能装插件；但那是外部依赖，上游删旧目录后 `opkg update` 会 404
3. Kwrt 把 `vermagic` 强写成 `1`（方便装任意 kmod），保留是双刃剑：装错版本照样崩，没有校验兜底
4. 上游 `devices/common` 里有几个补丁（如 `default-packages.patch`）会碰 `include/target.mk`，与去推广的 sed 相邻；一旦上游改结构，补丁可能冲突，届时按日志修

## 许可

上游 Kwrt 与 OpenWrt 均为 GPL-2.0，本仓库继承。Argon 主题为 Apache-2.0 / MIT。
