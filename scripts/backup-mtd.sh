#!/bin/bash
# ==============================================================================
# 刷机前分区备份（需求 §65）
#
# ⚠️  本脚本不会自动执行，也不在 build.sh 中调用。
# ⚠️  必须在原厂固件取得 root 后，由人工在【设备本机】执行（不是构建主机）。
# ⚠️  执行前必须先 cat /proc/mtd 核对分区编号：不同批次编号不同，禁止照抄。
#
# 用法（在路由器上）: sh backup-mtd.sh
# ==============================================================================
set -u

OUT="/tmp/r1c-backup-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT"

echo "=============================================="
echo " R1C 刷机前备份  (只读操作，不写入任何分区)"
echo "=============================================="

echo "--- 当前分区表（请拍照存档）---"
cat /proc/mtd

# 按名称解析分区号，避免硬编码编号出错
dump() {
    NAME="$1"
    DEV=$(grep "\"$NAME\"" /proc/mtd | cut -d: -f1)
    if [ -z "$DEV" ]; then
        echo "  ⚠️  未找到分区: $NAME"
        return
    fi
    echo "  备份 $NAME ($DEV) -> $OUT/${DEV}_${NAME}.bin"
    dd if="/dev/$DEV" of="$OUT/${DEV}_${NAME}.bin" 2>/dev/null
}

echo "--- 备份关键分区 ---"
dump "Factory"      # 无线 EEPROM/校准数据 + MAC（最关键，丢失不可恢复）
dump "Bdata"        # 板级数据
dump "Config"       # U-Boot 配置
dump "u-boot-env"   # OpenWrt 视图下的环境变量分区
dump "OS1"          # 原厂系统 1
dump "OS2"          # 原厂系统 2（体积大，失败可忽略）

echo "--- 备份当前配置 ---"
tar czf "$OUT/etc-config.tar.gz" /etc/config 2>/dev/null

echo "--- 记录 MAC ---"
{
    echo "# ifconfig -a"; ifconfig -a
    echo "# ethtool/eth0"; ethtool -P eth0 2>/dev/null
} > "$OUT/mac.txt" 2>/dev/null

echo ""
echo "✅ 备份完成: $OUT"
echo "👉 请立即用 scp 拷贝到电脑保存："
echo "   scp -O root@192.168.31.1:$OUT/* ./"
echo ""
echo "❌ 本脚本不会执行任何 mtd write / sysupgrade / U-Boot 操作"
