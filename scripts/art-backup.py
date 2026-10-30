#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从全量磁盘备份里定位并校验 ART（WiFi 校准）分区。

京东云亚瑟 AX1800 Pro（ipq6018-jdcloud_re-ss-01）的 0:ART 在 mmcblk0p15，
里面是每台机器唯一的射频校准与 MAC，写坏不可重建。这个脚本用来回答两个问题：

  1. 我手上这份 SSH 全量备份，到底有没有把 ART 备进去？
  2. 备进去的那一份是完整的、还是空的 / 被截断的？

用法（Windows / Linux / macOS 都行，只需 python3）：

    python scripts/art-backup.py D:\\backup\\mmcblk0.img
    python scripts/art-backup.py D:\\backup\\mmcblk0.img --extract art.bin
    python scripts/art-backup.py art_old.bin --compare art_new.bin

只读，不会修改输入文件。
"""

import argparse
import binascii
import hashlib
import os
import struct
import sys

SECTOR = 512
GPT_SIG = b"EFI PART"
# 单分区镜像分析上限：ART 一般 4~64 MB，读这么多足够，避免误传 14 GB 全盘卡死
MAX_ANALYZE = 64 * 1024 * 1024
CAL_OFF = 0x1000   # cal-ahb-c000000.wifi.bin 在 ART 内的偏移
CAL_LEN = 0x10000  # 64 KiB


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def read_at(f, off, n):
    f.seek(off)
    return f.read(n)


def parse_gpt(f, size):
    """返回 (header_dict, entries)；不是 GPT 则返回 (None, [])。"""
    hdr = read_at(f, SECTOR, 512)
    if len(hdr) < 92 or hdr[:8] != GPT_SIG:
        return None, []

    hdr_size = struct.unpack_from("<I", hdr, 12)[0]
    if hdr_size > 512:
        return None, []
    raw = hdr[:hdr_size]

    # 用 CRC 确认是真的 GPT，而不是别的东西碰巧带签名
    crc_stored = struct.unpack_from("<I", raw, 16)[0]
    crc_calc = binascii.crc32(raw[:16] + b"\x00\x00\x00\x00" + raw[20:]) & 0xFFFFFFFF

    info = {
        "header_size": hdr_size,
        "current_lba": struct.unpack_from("<Q", raw, 24)[0],
        "backup_lba": struct.unpack_from("<Q", raw, 32)[0],
        "first_usable": struct.unpack_from("<Q", raw, 40)[0],
        "last_usable": struct.unpack_from("<Q", raw, 48)[0],
        "entry_lba": struct.unpack_from("<Q", raw, 72)[0],
        "entry_num": struct.unpack_from("<I", raw, 80)[0],
        "entry_size": struct.unpack_from("<I", raw, 84)[0],
        "crc_ok": crc_stored == crc_calc,
    }

    nbytes = info["entry_num"] * info["entry_size"]
    if nbytes <= 0 or nbytes > 4 * 1024 * 1024:
        return info, []
    blob = read_at(f, info["entry_lba"] * SECTOR, nbytes)
    if len(blob) < nbytes:
        return info, []

    entries = []
    for i in range(info["entry_num"]):
        e = blob[i * info["entry_size"]:(i + 1) * info["entry_size"]]
        if len(e) < 128:
            break
        if e[0:16] == b"\x00" * 16:
            continue  # 未使用
        first = struct.unpack_from("<Q", e, 32)[0]
        last = struct.unpack_from("<Q", e, 40)[0]
        try:
            name = e[56:128].decode("utf-16-le", "ignore").rstrip("\x00")
        except Exception:
            name = ""
        entries.append({
            "index": i + 1,
            "name": name,
            "first": first,
            "last": last,
            "sectors": last - first + 1 if last >= first else 0,
            "offset": first * SECTOR,
        })
    return info, entries


def sniff(blob):
    """粗判一块数据像不像 ART。"""
    if not blob:
        return "空"
    if blob.count(0) == len(blob):
        return "全 0"
    if blob.count(0xFF) == len(blob):
        return "全 FF"
    return "有数据"


def analyze(blob, label="ART"):
    """对一段拟作 ART 的数据做体检，返回若干行文本。"""
    out = []
    out.append("  长度        : %d 字节 (%s)" % (len(blob), human(len(blob))))
    out.append("  前 0x1000   : %s" % sniff(blob[:0x1000]))

    if len(blob) >= CAL_OFF + CAL_LEN:
        cal = blob[CAL_OFF:CAL_OFF + CAL_LEN]
        state = sniff(cal)
        out.append("  cal 块      : %s  (%s)" % (
            state, "0x1000 起 64 KiB"))
        if state in ("全 0", "全 FF", "空"):
            out.append("  [X] cal 块是空的 —— 这份备份里的 ART 没有可用校准数据")
        else:
            nz = len(cal) - cal.count(0)
            out.append("             非零字节 %d / %d (%.1f%%)" % (
                nz, len(cal), 100.0 * nz / len(cal)))
            out.append("  [OK] cal 块有内容，可以当提取源")
    else:
        out.append("  [X] 长度不足 0x11000，取不出完整 cal 块")

    out.append("  MD5(整段)   : %s" % hashlib.md5(blob).hexdigest())
    if len(blob) >= CAL_OFF + CAL_LEN:
        out.append("  MD5(cal块)  : %s" % hashlib.md5(
            blob[CAL_OFF:CAL_OFF + CAL_LEN]).hexdigest())

    head = blob[:64]
    out.append("  头部 64 B   : %s" % head.hex())
    return out


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    ap = argparse.ArgumentParser(
        description="校验京东云亚瑟全量备份里的 ART（0:ART / mmcblk0p15）")
    ap.add_argument("image", help="全量磁盘镜像，或单分区 ART 文件")
    ap.add_argument("--extract", metavar="OUT", help="把 ART 切出来另存")
    ap.add_argument("--compare", metavar="FILE", help="与另一份 ART 比对是否一致")
    args = ap.parse_args()

    if not os.path.isfile(args.image):
        print("[X] 文件不存在: %s" % args.image)
        return 2

    size = os.path.getsize(args.image)
    print("=" * 66)
    print("文件: %s" % args.image)
    print("大小: %d 字节 (%s, %d 扇区)" % (size, human(size), size // SECTOR))
    print("=" * 66)

    with open(args.image, "rb") as f:
        info, entries = parse_gpt(f, size)

        if info is None:
            print("\n[!] 没有找到 GPT 头 —— 这不是整盘镜像，按单分区 ART 处理")
            print("    （如果你本意是给整盘 dd 镜像，说明镜像头被截断或不是从 LBA0 开始）")
            blob = read_at(f, 0, min(size, MAX_ANALYZE))
            print()
            for line in analyze(blob):
                print(line)
            if args.extract:
                with open(args.extract, "wb") as o:
                    o.write(blob)
                print("\n已另存: %s" % args.extract)
            if args.compare:
                other = open(args.compare, "rb").read(MAX_ANALYZE)
                print("\n比对结果: %s" % (
                    "完全一致" if other == blob else "不一致（可能不是同一台机器）"))
            return 0

        # ---- 是 GPT 镜像 ----
        print("GPT : 签名有效, %s" % ("CRC 通过" if info["crc_ok"] else "[!] CRC 不符"))
        print("      分区项 %d 个 / 每项 %d 字节, 首可用 LBA %d, 末可用 LBA %d"
              % (info["entry_num"], info["entry_size"],
                 info["first_usable"], info["last_usable"]))
        disk_lba = info["last_usable"] + 1
        if size // SECTOR < disk_lba:
            print("      [X] 文件只有 %d 扇区，GPT 声明到 %d —— 备份被截断"
                  % (size // SECTOR, disk_lba))
        else:
            print("      [OK] 文件覆盖到 GPT 声明的末 LBA，是全盘镜像")

        print("\n分区表:")
        print("  %-4s %-14s %-12s %-12s %s" % ("#", "名称", "起始 LBA", "扇区数", "大小"))
        art = None
        for e in entries:
            mark = ""
            if "art" in e["name"].lower():
                mark = "  <== ART"
                if art is None:
                    art = e
            print("  %-4d %-14s %-12d %-12d %s%s" % (
                e["index"], e["name"] or "(无名)", e["first"], e["sectors"],
                human(e["sectors"] * SECTOR), mark))

        if art is None:
            print("\n[X] 分区表里没有名字含 ART 的项。")
            print("    亚瑟应当是 '0:ART'。若你刷过第三方 GPT，分区名可能被改，")
            print("    请把上面这张表发我，我按偏移帮你定位。")
            return 1

        # ---- 切出 ART ----
        need = art["sectors"] * SECTOR
        if art["offset"] + need > size:
            avail = max(0, size - art["offset"])
            print("\n[X] ART 在偏移 0x%X，需要 %s，但文件只剩 %s —— 备份不完整"
                  % (art["offset"], human(need), human(avail)))
            return 1

        blob = read_at(f, art["offset"], need)
        print("\nART 分区: #%d  名称 '%s'" % (art["index"], art["name"]))
        print("  偏移        : 0x%X (%d)" % (art["offset"], art["offset"]))
        print("  扇区        : %d ~ %d" % (art["first"], art["last"]))
        print()
        for line in analyze(blob):
            print(line)

        if args.extract:
            with open(args.extract, "wb") as o:
                o.write(blob)
            print("\n已切出: %s  (%s)" % (args.extract, human(len(blob))))
            print("请把它与镜像分开保存，别只留一份。")

        if args.compare:
            other = open(args.compare, "rb").read()
            same = other == blob
            print("\n比对: %s" % ("两份 ART 完全一致" if same
                                 else "不一致（不是同一台机器的 ART，或其中一份被改过）"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
