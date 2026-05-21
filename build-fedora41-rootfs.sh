#!/bin/bash
set -e

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
FEDORA_VERSION="41"
FEDORA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/fedora"

usage() { echo "用法: $0 <kernel_version>"; exit 1; }
[ $# -ne 1 ] && usage
[ "$(id -u)" -ne 0 ] && { echo "请使用root权限运行"; exit 1; }

KERNEL=$1
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="fedora41_${TIMESTAMP}.img"

echo "=========================================="
echo "开始构建 Fedora $FEDORA_VERSION (ARM64) RootFS"
echo "将从 kernel-bundle-$KERNEL 中提取固件并注入"
echo "=========================================="

# --- 准备工作：提取 kernel-bundle 中的固件 ---
# 临时目录用于解压所有 .deb 包，但最终只提取 firmware
FW_TEMP_DIR=$(mktemp -d)
FW_SOURCE_DIR=""

# 解压所有 .deb 包到临时目录
for deb in *.deb; do
    echo "正在解压 $deb ..."
    dpkg-deb -x "$deb" "$FW_TEMP_DIR"
done

# 查找临时目录中的 /lib/firmware 目录
if [ -d "$FW_TEMP_DIR/lib/firmware" ]; then
    FW_SOURCE_DIR="$FW_TEMP_DIR/lib/firmware"
    echo "✅ 成功找到固件目录"
else
    echo "⚠️ 未在解压后的目录中发现 /lib/firmware，将跳过固件注入"
fi

# --- 1. 创建空白 ext4 镜像并挂载 ---
rm -rf rootdir || true
truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# --- 2. 使用 dnf 安装基础系统（--installroot）---
# 确保 dnf 命令存在（工作流会提前安装）
dnf --installroot=rootdir \
    --releasever=$FEDORA_VERSION \
    --forcearch=aarch64 \
    --nogpgcheck \
    --setopt=reposdir=/dev/null \
    --repofrompath=fedora,$FEDORA_MIRROR/releases/$FEDORA_VERSION/Everything/aarch64/os \
    --repofrompath=fedora-updates,$FEDORA_MIRROR/updates/$FEDORA_VERSION/Everything/aarch64/os \
    install -y \
    systemd sudo dnf kernel-core \
    NetworkManager openssh-server \
    passwd glibc-langpack-en

# --- 3. 注入固件 ---
if [ -n "$FW_SOURCE_DIR" ]; then
    echo "📡 正在将提取的固件合并到 Fedora 系统..."
    mkdir -p rootdir/lib/firmware
    cp -rf $FW_SOURCE_DIR/* rootdir/lib/firmware/
    echo "✅ 固件合并完成"
fi

# --- 4. 挂载虚拟文件系统（用于 systemctl 等）---
mount --bind /dev rootdir/dev
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

# --- 5. 基础配置 ---
chroot rootdir /bin/bash -c "echo 'LANG=en_US.UTF-8' > /etc/locale.conf"
chroot rootdir /bin/bash -c "echo 'fedora41' > /etc/hostname"
chroot rootdir /bin/bash -c "echo -e '1234\n1234' | passwd root"
chroot rootdir systemctl enable NetworkManager sshd

# --- 6. 创建普通用户 ---
chroot rootdir useradd -m -s /bin/bash luser
chroot rootdir bash -c "echo 'luser:luser' | chpasswd"
chroot rootdir usermod -aG wheel luser

# --- 7. 安装 GNOME 桌面 ---
chroot rootdir dnf groupinstall -y "GNOME Desktop" "GNOME Applications" "Standard"
chroot rootdir systemctl set-default graphical.target
chroot rootdir systemctl enable gdm

# --- 8. 清理 ---
chroot rootdir dnf clean all
rm -rf rootdir/var/cache/dnf
sync; sleep 2

# --- 9. 卸载镜像 ---
umount rootdir/dev rootdir/proc rootdir/sys 2>/dev/null || true
umount rootdir || true
rm -rf rootdir
rm -rf "$FW_TEMP_DIR"

# --- 10. 固定 UUID 并压缩 ---
tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
echo "✅ 镜像生成: $ROOTFS_IMG"
echo "🗜️ 压缩中..."
7z a "${ROOTFS_IMG}.7z" "$ROOTFS_IMG"
echo "🎉 完成！输出: ${ROOTFS_IMG}.7z"
