#!/bin/bash
set -e

# 🛡️ 异常清理守护
cleanup() {
    umount -l rootdir/dev/pts 2>/dev/null || true
    umount -l rootdir/dev 2>/dev/null || true
    umount -l rootdir/proc 2>/dev/null || true
    umount -l rootdir/sys 2>/dev/null || true
    umount -l rootdir 2>/dev/null || true
}
trap cleanup EXIT ERR

IMAGE_SIZE="8G"
DEBIAN_SUITE="trixie"
DEBIAN_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"

if [ $# -ne 2 ]; then
    echo "用法: $0 <distro_name> <kernel_version>"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行"
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="debian13_desktop_${TIMESTAMP}.img"

truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 -L linux "$ROOTFS_IMG"
mkdir -p rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# 基础自举
debootstrap --arch=arm64 "$DEBIAN_SUITE" rootdir "$DEBIAN_MIRROR"

# 挂载虚拟文件系统
mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

# 配置 APT 源
printf "deb %s %s main non-free-firmware contrib\n" "$DEBIAN_MIRROR" "$DEBIAN_SUITE" > rootdir/etc/apt/sources.list

export DEBIAN_FRONTEND=noninteractive
chroot rootdir apt-get update
chroot rootdir apt-get install -y eatmydata

# 核心组件与中文、输入法、Flatpak
chroot rootdir eatmydata apt-get install -y --no-install-recommends \
    task-gnome-desktop gdm3 systemd-resolved \
    locales fonts-noto-cjk \
    fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk4 fcitx5-frontend-qt5 \
    flatpak gnome-software-plugin-flatpak \
    gnome-tweaks gnome-shell-extension-manager \
    xdg-desktop-portal-gnome maliit-keyboard

# 配置中文环境
chroot rootdir bash -c "sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen"
chroot rootdir locale-gen
chroot rootdir bash -c "echo 'LANG=zh_CN.UTF-8' > /etc/default/locale"

# 配置 Fcitx5 环境变量
cat <<EOF > rootdir/etc/environment
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF

# 用户配置
chroot rootdir useradd -m -s /bin/bash luser
echo "luser:luser" | chroot rootdir chpasswd
chroot rootdir usermod -aG sudo,audio,video,render,input luser

# 平板底层补丁与触控矩阵
chroot rootdir bash -c "echo 'ttyMSM0' >> /etc/securetty"
mkdir -p rootdir/etc/udev/rules.d/
printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules

# GDM 自动登录
mkdir -p rootdir/etc/gdm3
printf "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=luser\n" > rootdir/etc/gdm3/daemon.conf
chroot rootdir systemctl enable gdm3 NetworkManager systemd-resolved

# 自动扩容与 Flatpak 设置
printf "PARTLABEL=linux / ext4 defaults,noatime,x-systemd.growfs 0 1\n" > rootdir/etc/fstab
chroot rootdir flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# 清理并压缩
chroot rootdir apt-get clean
cleanup
7z a -t7z -m0=lzma2 -mx=5 -mmt=on "debian13_desktop_${TIMESTAMP}.7z" "$ROOTFS_IMG"
rm -f "$ROOTFS_IMG"

echo "✅ 构建完成！镜像已支持中文、Fcitx5 和 Flatpak。"
