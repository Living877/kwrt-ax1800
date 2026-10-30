# AX1800 Pro 全量备份说明

> 备份时间：2026-10-30
> 机器：京东云 AX1800 Pro（JDCloud RE-SS-01，IPQ6000）
> 来源：实机 SSH，通过 `/dev/mmcblk0p20` 中转后 scp 回电脑

## 一、文件清单与用途

| 文件 | 大小 | 内容 | 恢复场景 | 敏感度 |
|---|---|---|---|---|
| `art.bin` | 256 KB | `0:ART` 整分区（p15，起始 LBA 15906，512 扇区） | 无线校准丢失、5G 起不来 | 私密（每机唯一） |
| `cal-from-p19.bin` | 64 KB | 旧 overlay 里现成的 cal 校准文件（MD5 与 ART 内 cal 块一致） | 同上，等价物 | 私密 |
| `mibib-gpt-8m.bin` | 8 MB | eMMC 前 8MB：GPT 分区表 + 各分区头 | 分区表被破坏 | 低 |
| `p4.bin` / `p5.bin` | 1.75 MB 各 | `0:QSEE` / `0:QSEE_1`（TrustZone）A/B 双份 | 引导损坏 | 中 |
| `devcfg-p6.bin` / `devcfg-p7.bin` | 256 KB 各 | `0:DEVCFG` / `0:DEVCFG_1` 设备配置 A/B（MAC/SN/设备唯一标识） | **丢失 MAC/SN，不可再生** | 高（含 MAC/SN） |
| `p13.bin` / `p14.bin` | 640 KB 各 | `0:APPSBL` / `0:APPSBL_1`（U-Boot 阶段）A/B | 变砖 | 低 |
| `MANIFEST.md5` | — | 全部文件 MD5 校验和 | 校验完整性 | — |

> **已移除**：`etc-config.tar.gz`（当前 `/etc/config` 快照，可再生）与 `old-overlay-secrets.tar.gz`（旧固件 ddnsto 等凭证，旧 overlay 已删无用）——两者均含敏感凭据且可重建，按「非系统级、可再生者不备份」原则删除。

## 二、关键发现

1. **`p13.bin` 与 `p14.bin` MD5 完全相同**（`1291cf11...`），说明 APPSBL 的 A/B 双份一致，引导从未被破坏过——机器健康。
2. **`cal-from-p19.bin` 的 MD5 是 `a5cb30f5...`**，与实机 `/lib/firmware/ath11k/IPQ6018/hw1.0/cal-ahb-c000000.wifi.bin` 完全一致，确认这就是本机校准数据。
3. **`devcfg-p6.bin` / `devcfg-p7.bin` 已与实机比对通过**：MD5 分别为 `ca54fb24...` / `a7037d07...`，与 `/dev/mmcblk0p6`、`/dev/mmcblk0p7` 完全一致。
4. `devcfg-p6.bin` 内是带 `Generated Test Attestation CA1` 签名的高通测试证书链 + DEVCFG 结构，属出厂配置，**刷机无法重建**——这是本清单里除 ART 外第二重要的不可再生项。

## 三、⚠️ 隐私提醒

本目录含敏感数据：
- **MAC / SN**（`devcfg-p6/p7.bin`，机器唯一标识）
- **无线校准数据**（`art.bin`、`cal-from-p19.bin`）

**切勿上传到公开仓库。** 若要异地备份，请使用私有仓库。

> 原 `etc-config.tar.gz`（shadow 哈希、WiFi 密码）与 `old-overlay-secrets.tar.gz`（ddnsto 明文 token `4f4081f5-...`）已于 2026-10-30 删除，不再存在于本目录。

### 加密备份包（`ax1800-加密备份.zip`）

本目录另有一份 **`ax1800-加密备份.zip`**（约 3.3 MB），是上面 9 个 `.bin` + `MANIFEST.md5` 的**带密码压缩包**，用于把不可再生的硬件数据安全地异地备份（含推送到仓库）。

- **加密格式**：Zip 传统加密（ZipCrypto），由 Bandizip 生成
- **解压密码**：见仓库所有者的私人记录（不写入本文件，避免密码与数据同处一地）
- **解密验证**：`flag_bits=0x1`（已加密），错误密码无法解出，正确密码可解出 262144 字节的 `art.bin`

> 密码请自行记住，不要写进 git 或任何公开位置。这份 zip 与明文 `.bin` 不同，`art.bin` 等原始二进制仍受 `.gitignore` 拦截、**不会**进仓库；加密包因含密码保护，允许上传。

## 四、恢复方法（仅在需要时）

```bash
# 校验完整性
md5sum -c MANIFEST.md5

# 恢复 ART（无线校准备份，写入 p15）
# ⚠️ 写之前务必再核对一次 md5，写错无线永久报废
dd if=art.bin of=/dev/mmcblk0p15 bs=512
# 或只恢复 cal 文件（更安全，只放 /lib/firmware）
mkdir -p /lib/firmware/ath11k/IPQ6018/hw1.0
cp cal-from-p19.bin /lib/firmware/ath11k/IPQ6018/hw1.0/cal-ahb-c000000.wifi.bin

# 恢复分区表（极少需要）
dd if=mibib-gpt-8m.bin of=/dev/mmcblk0 bs=512 count=16384

# 恢复 DEVCFG（MAC/SN 丢失时，如 MAC 变成 00:00:00:00:00:00）
dd if=devcfg-p6.bin of=/dev/mmcblk0p6 bs=512
dd if=devcfg-p7.bin of=/dev/mmcblk0p7 bs=512
```

## 五、p19 的真相（回答"是不是软件安装目录"）

**不是。** p19/p20 是京东云分出来的两个数据盘（ext4），旧固件和当前 Kwrt 都只把它们当**数据盘**用（docker 数据、下载、samba 共享），软件一直装在根文件系统的 `/overlay`（当前是 `/dev/loop0`，2G）。

p19 里原有那 496MB 是**旧固件的完整 overlay 快照**（`upper/` 目录），属刷机前残留。该快照已于 2026-10-30 移入 `.trash-20261030` 后彻底删除，**p19 现为完整空盘**（4.8G 容量，占用 0%，仅剩 ext4 的 `lost+found` 与 `.fs_state` 软链），已挂载于 `/mnt/mmcblk0p19` 并写入 fstab 开机自动挂载。
