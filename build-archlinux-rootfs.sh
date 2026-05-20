#!/bin/bash
set -e

IMAGE_SIZE="4G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

usage() {
    echo "用法: $0 <server|desktop> <firmware_extract_dir>"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

VARIANT=$1
FIRMWARE_DIR="$2"

if [[ "$VARIANT" != "server" && "$VARIANT" != "desktop" ]]; then
    echo "错误: variant 必须是 server 或 desktop"
    exit 1
fi

if [ ! -d "$FIRMWARE_DIR/lib/firmware" ]; then
    echo "警告: 在 $FIRMWARE_DIR 中未找到 lib/firmware，将跳过固件复制"
    FIRMWARE_AVAILABLE=false
else
    FIRMWARE_AVAILABLE=true
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行"
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="archlinux_${VARIANT}_${TIMESTAMP}.img"

echo "=========================================="
echo "开始构建 Arch Linux RootFS ($VARIANT)"
echo "将${FIRMWARE_AVAILABLE:+ 包含从 Debian 包提取的固件}"
echo "=========================================="

rm -rf rootdir || true
truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# 下载官方 Arch Linux ARM 基础 tarball
BASE_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
echo "⬇️ 下载基础系统: $BASE_URL"
wget --progress=dot:giga -O archlinuxarm.tar.gz "$BASE_URL"
echo "📦 解压到镜像..."
tar -xzf archlinuxarm.tar.gz -C rootdir
rm archlinuxarm.tar.gz

# 复制固件（如果可用）
if [ "$FIRMWARE_AVAILABLE" = true ]; then
    echo "📡 复制 Debian 固件到 /lib/firmware ..."
    mkdir -p rootdir/lib/firmware
    cp -r $FIRMWARE_DIR/lib/firmware/* rootdir/lib/firmware/
    echo "✅ 固件已复制"
fi

# 挂载虚拟文件系统（用于后续 chroot）
mount --bind /dev rootdir/dev
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

# 配置 pacman 镜像源（清华）
cat > rootdir/etc/pacman.d/mirrorlist <<'EOF'
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
EOF

# 在 chroot 内安装附加软件包
if [ "$VARIANT" = "desktop" ]; then
    echo "🖥️ 安装桌面环境 (Plasma, SDDM, Firefox)..."
    chroot rootdir /bin/bash -c "
        pacman -Sy --noconfirm
        pacman -S --noconfirm --needed xorg-server plasma-desktop sddm firefox
        systemctl enable sddm
        useradd -m -G wheel -s /bin/bash arch
        echo 'arch:arch' | chpasswd
        echo 'arch ALL=(ALL) ALL' >> /etc/sudoers
        echo 'arch-${VARIANT}' > /etc/hostname
    "
else
    echo "⚙️ 安装服务器版基础包 (OpenSSH)..."
    chroot rootdir /bin/bash -c "
        pacman -Sy --noconfirm
        pacman -S --noconfirm --needed openssh
        systemctl enable sshd
        echo 'arch-${VARIANT}' > /etc/hostname
    "
fi

# 清理 pacman 缓存
chroot rootdir pacman -Scc --noconfirm 2>/dev/null || true

# 卸载挂载点
umount rootdir/dev rootdir/proc rootdir/sys 2>/dev/null || true
umount rootdir || true
rm -rf rootdir

# 固定 UUID
tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"

echo "✅ 镜像生成: $ROOTFS_IMG"
echo "🗜️ 压缩中..."
7z a "${ROOTFS_IMG}.7z" "$ROOTFS_IMG"
echo "🎉 完成！输出文件: ${ROOTFS_IMG}.7z"
