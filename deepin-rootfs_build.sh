#!/bin/bash
set -e

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

# 🎯 核心修改：锁定 Deepin 25.1.0 最新代号 crimson，直连官方主源
DEBIAN_SUITE="crimson"
DEBIAN_MIRROR="https://community-packages.deepin.com/deepin/"

usage() {
    echo "用法: $0 <distro_name> <kernel_version>"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行"
    exit 1
fi

# 🛡️ 智能检测防御：如果 Deepin 官方主源还在调整 25.1 的 Release 结构，自动切回滚动核心 beige
if curl -sI "${DEBIAN_MIRROR}dists/${DEBIAN_SUITE}/Release" | grep -q "404 Not Found"; then
    echo "⚠️ 官方主源 crimson (Deepin 25) 索引维护中，平滑切入 beige 分支获取 25.1 滚动更新..."
    DEBIAN_SUITE="beige"
fi

DISTRO=$1
KERNEL=$2
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="deepin25_1_0_desktop_${TIMESTAMP}.img"

echo "=========================================="
echo "⏳ 开始构建最前沿版 Deepin 25.1.0 RootFS"
echo "内核版本: $KERNEL"
echo "目标分支: $DEBIAN_SUITE"
echo "=========================================="

rm -rf rootdir || true
truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# 欺骗 debootstrap，映射对应的 Deepin 代号
if [ ! -f "/usr/share/debootstrap/scripts/${DEBIAN_SUITE}" ]; then
    echo "🔗 正在映射 debootstrap 构建脚本..."
    ln -sf /usr/share/debootstrap/scripts/sid "/usr/share/debootstrap/scripts/${DEBIAN_SUITE}"
fi

# 基础系统自举安装 (跳过初期的 GPG 校验，直连官方)
debootstrap --no-check-gpg --arch=arm64 "$DEBIAN_SUITE" rootdir "$DEBIAN_MIRROR"

mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

# 写入专属官方源并强制信任 (商业组件和社区组件一并抓取)
printf "deb [trusted=yes] %s %s main commercial community\n" "$DEBIAN_MIRROR" "$DEBIAN_SUITE" > rootdir/etc/apt/sources.list

cp /etc/resolv.conf rootdir/etc/
chroot rootdir apt update

# 安装定制的 7.0 高通内核与驱动包，并自动修复依赖
if ls *.deb 1> /dev/null 2>&1; then
    cp *.deb rootdir/tmp/
    chroot rootdir bash -c "apt install -y /tmp/*.deb || apt-get install -f -y"
fi

# 安装基础组件和引导生成工具
chroot rootdir apt install -y --no-install-recommends \
    deepin-keyring systemd systemd-resolved sudo vim-tiny wget curl network-manager wpasupplicant dbus locales initramfs-tools

# 语言环境
chroot rootdir bash -c "echo 'LANG=en_US.UTF-8' > /etc/default/locale"
chroot rootdir sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
chroot rootdir locale-gen en_US.UTF-8

# 密码设置
chroot rootdir bash -c "echo -e '1234\n1234' | passwd root"
echo "deepin-sheng" > rootdir/etc/hostname

# 安装 Deepin 核心桌面包 (dde 包含了控制中心、文件管理器等全家桶)
chroot rootdir apt install -y --no-install-recommends dde lightdm

# 创建普通用户 (luser / luser)
chroot rootdir useradd -m -s /bin/bash luser
echo "luser:luser" | chroot rootdir chpasswd
chroot rootdir usermod -aG sudo,audio,video,render,input luser

echo "🩹 正在注入底层自愈补丁..."
chroot rootdir bash -c "echo 'ttyMSM0' >> /etc/securetty"
ln -sf /lib/systemd/system/getty@.service rootdir/etc/systemd/system/getty.target.wants/getty@ttyMSM0.service

# 高通 WiFi 固件伪装
if [ -f "rootdir/lib/firmware/ath12k/WCN7850/hw2.0/board-2.bin" ]; then
    cp rootdir/lib/firmware/ath12k/WCN7850/hw2.0/board-2.bin rootdir/lib/firmware/ath12k/WCN7850/hw2.0/board.bin
fi

# 激活 DNS 与触控规则
chroot rootdir systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf rootdir/etc/resolv.conf
mkdir -p rootdir/etc/udev/rules.d/
printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules

# Deepin LightDM 自动登录
mkdir -p rootdir/etc/lightdm/lightdm.conf.d
printf "[Seat:*]\nautologin-user=luser\nautologin-user-timeout=0\n" > rootdir/etc/lightdm/lightdm.conf.d/12-autologin.conf
chroot rootdir systemctl enable lightdm
chroot rootdir systemctl set-default graphical.target
printf "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1\n" > rootdir/etc/fstab

# 强制生成引导
echo "🔄 强制重新生成 initramfs 引导镜像..."
chroot rootdir bash -c "update-initramfs -u -k all"

chroot rootdir apt clean
chroot rootdir rm -rf /tmp/*.deb

umount rootdir/dev/pts || true
umount rootdir/dev || true
umount rootdir/proc || true
umount rootdir/sys || true
umount rootdir || true
rm -rf rootdir

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"

echo "✅ 镜像生成完成: $ROOTFS_IMG"
echo "🗜️ 正在生成最终 7z 压缩包..."
7z a "deepin25_1_0_desktop_${TIMESTAMP}.7z" "$ROOTFS_IMG"
rm -f "$ROOTFS_IMG"

echo "🎉 Deepin 25.1.0 自动化编译全部圆满成功！"
