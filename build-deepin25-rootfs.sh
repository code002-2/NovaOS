#!/bin/bash
set -e

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

# Deepin 25 配置
DEEPIN_SUITE="crimson"
# 使用已验证的镜像源（包含 Release 文件）
DEEPIN_MIRROR="https://mirrors.cernet.edu.cn/deepin/beige"

usage() {
    echo "用法: $0 <kernel_version>"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行"
    exit 1
fi

KERNEL=$1

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="deepin25_${TIMESTAMP}.img"

echo "=========================================="
echo "开始构建 Deepin 25 (crimson) RootFS"
echo "内核版本: $KERNEL"
echo "语言环境: 英文 (en_US.UTF-8)"
echo "=========================================="

rm -rf rootdir || true
truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# 第一阶段：使用 --foreign 下载并解压基础系统
debootstrap --arch=arm64 --foreign "$DEEPIN_SUITE" rootdir "$DEEPIN_MIRROR"

# 复制 QEMU 静态二进制（如果需要跨架构，但 runner 是 arm64 则不需要）
# 以下仅为兼容性保留，实际在 arm64 runner 上可省略
if [ "$(uname -m)" != "aarch64" ]; then
    cp /usr/bin/qemu-aarch64-static rootdir/usr/bin/
fi

# 第二阶段：完成 debootstrap 安装
chroot rootdir /debootstrap/debootstrap --second-stage

# 挂载虚拟文件系统
mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

# 配置 APT 源（官方源 + 清华源备份）
cat > rootdir/etc/apt/sources.list <<EOF
deb $DEEPIN_MIRROR $DEEPIN_SUITE main commercial community
deb https://mirrors.tuna.tsinghua.edu.cn/deepin $DEEPIN_SUITE main commercial community
EOF

chroot rootdir apt update

# 安装内核包（如果有）
if ls *.deb 1> /dev/null 2>&1; then
    cp *.deb rootdir/tmp/
    chroot rootdir bash -c "apt install -y /tmp/*.deb || true"
fi

# 基础包
chroot rootdir apt install -y --no-install-recommends \
    systemd sudo vim-tiny wget curl \
    network-manager openssh-server \
    wpasupplicant dbus

# 英文 locale
chroot rootdir bash -c "echo 'LANG=en_US.UTF-8' > /etc/default/locale"
chroot rootdir locale-gen en_US.UTF-8

# root 密码
chroot rootdir bash -c "echo -e '1234\n1234' | passwd root"
echo "deepin25" > rootdir/etc/hostname

# 安装 DDE 桌面
chroot rootdir apt install -y --no-install-recommends \
    dde \
    dde-file-manager \
    deepin-terminal \
    firefox-esr \
    lightdm

# 创建普通用户
chroot rootdir useradd -m -s /bin/bash luser
echo "luser:luser" | chroot rootdir chpasswd
chroot rootdir usermod -aG sudo luser

# LightDM 自动登录
mkdir -p rootdir/etc/lightdm/lightdm.conf.d
cat > rootdir/etc/lightdm/lightdm.conf.d/autologin.conf <<EOF
[Seat:*]
autologin-user=luser
autologin-user-timeout=0
EOF

chroot rootdir systemctl enable lightdm
chroot rootdir systemctl set-default graphical.target

# fstab
cat > rootdir/etc/fstab <<EOF
PARTLABEL=linux / ext4 defaults 0 1
EOF

chroot rootdir apt clean
chroot rootdir rm -rf /tmp/*.deb

# 卸载
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
