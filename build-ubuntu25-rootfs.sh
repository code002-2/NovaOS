#!/bin/bash
set -e

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

usage() {
    echo "用法: $0 <variant> <kernel_version>"
    echo "variant: server 或 desktop"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行"
    exit 1
fi

VARIANT=$1
KERNEL=$2

if [[ "$VARIANT" != "server" && "$VARIANT" != "desktop" ]]; then
    echo "错误: variant 必须是 server 或 desktop"
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="ubuntu24_${VARIANT}_${TIMESTAMP}.img"

echo "=========================================="
echo "开始构建 Ubuntu 24.04 (Noble) RootFS"
echo "变体: $VARIANT"
echo "内核版本: $KERNEL"
echo "镜像: $ROOTFS_IMG"
echo "=========================================="

rm -rf rootdir || true

truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"

mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# 关键修复：直接写死 suite 和 mirror，不使用任何变量
debootstrap --arch=arm64 noble rootdir http://archive.ubuntu.com/ubuntu

mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

if ls *.deb 1> /dev/null 2>&1; then
    cp *.deb rootdir/tmp/
    echo "安装内核及驱动包..."
    chroot rootdir bash -c "apt update && apt install -y /tmp/*.deb || true"
else
    echo "警告: 未找到任何.deb包，请确保内核bundle已下载"
fi

chroot rootdir apt update
chroot rootdir apt install -y \
    systemd sudo vim wget curl \
    network-manager openssh-server \
    wpasupplicant dbus ubuntu-drivers-common

chroot rootdir bash -c "echo -e '1234\n1234' | passwd root"
echo "ubuntu24-${VARIANT}" > rootdir/etc/hostname

if [ "$VARIANT" = "desktop" ]; then
    chroot rootdir apt install -y \
        ubuntu-desktop-minimal \
        gnome-terminal \
        firefox \
        gdm3

    chroot rootdir useradd -m -s /bin/bash luser
    echo "luser:luser" | chroot rootdir chpasswd
    chroot rootdir usermod -aG sudo luser

    mkdir -p rootdir/etc/gdm3
    cat > rootdir/etc/gdm3/daemon.conf <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=luser
EOF

    chroot rootdir systemctl enable gdm3
    chroot rootdir systemctl set-default graphical.target
else
    chroot rootdir systemctl enable ssh
    chroot rootdir systemctl enable NetworkManager
    chroot rootdir systemctl set-default multi-user.target
fi

cat > rootdir/etc/fstab <<EOF
PARTLABEL=linux / ext4 defaults 0 1
EOF

chroot rootdir apt clean

umount rootdir/dev/pts || true
umount rootdir/dev || true
umount rootdir/proc || true
umount rootdir/sys || true
umount rootdir || true
rm -rf rootdir

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"

echo "✅ 镜像生成: $ROOTFS_IMG"
echo "🗜️ 压缩中..."
7z a "${ROOTFS_IMG}.7z" "$ROOTFS_IMG"
echo "🎉 完成！输出文件: ${ROOTFS_IMG}.7z"
