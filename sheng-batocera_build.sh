#!/bin/bash
set -e

IMAGE_SIZE="4G" # Batocera 核心很小，4G 足够装系统加一点内置游戏了
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
IMG_NAME="batocera_sm8550_sheng_${TIMESTAMP}.img"

echo "======================================"
echo "🚀 开始组装Batocera"
echo "======================================"

# ==========================================
# 🛡️ 容错防线：挂载点清理
# ==========================================
cleanup_mounts() {
    echo "🧹 清理挂载点..."
    fuser -k -9 -m rootdir 2>/dev/null || true
    sleep 1
    umount -l rootdir 2>/dev/null || true
    rm -rf rootdir
}
trap cleanup_mounts EXIT ERR INT TERM

cleanup_mounts 
mkdir -p rootdir

echo "💽 正在创建空的 EXT4 镜像 (${IMAGE_SIZE})..."
truncate -s $IMAGE_SIZE "$IMG_NAME"

# 🚨 极其关键的一步：Batocera 的 initrd 靠这个 Label 来找系统！
mkfs.ext4 -L BATOCERA -O ^metadata_csum "$IMG_NAME"
mount -o loop "$IMG_NAME" rootdir

echo "📂 正在注入 Batocera 系统目录结构..."
mkdir -p rootdir/boot
mkdir -p rootdir/userdata # 预留给用户存游戏的目录

echo "⬇️ 正在复制内核与设备树 (提取自 Kernel Bundle)..."
# YAML 会提前把你下载的 kernel.deb 解压到 kernel_ext 目录
cp kernel_ext/boot/vmlinuz-* rootdir/Image || echo "⚠️ 找不到内核 Image"
cp kernel_ext/usr/lib/linux-image-*/*.dtb rootdir/sm8550-xiaomi-sheng.dtb || echo "⚠️ 找不到 .dtb 设备树"

echo "⬇️ 正在复制 Batocera 编译产物 (Squashfs & Initramfs)..."
cp output/images/rootfs.squashfs rootdir/boot/batocera
cp output/images/rootfs.cpio.gz rootdir/initrd.gz

echo "🧹 解除挂载并应用 UUID..."
cleanup_mounts
tune2fs -U $FILESYSTEM_UUID "$IMG_NAME"

echo "🔄 转换为 Sparse Image 并压缩..."
SPARSE_IMG="sparse_${IMG_NAME}"
img2simg "$IMG_NAME" "$SPARSE_IMG"
7z a "${IMG_NAME%.img}.7z" "$SPARSE_IMG"
rm -f "$IMG_NAME" "$SPARSE_IMG"

echo "🎉 Batocera 单分区刷机包打包完成！"
