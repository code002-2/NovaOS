#!/bin/bash
set -e

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

usage() {
    echo "用法: $0 <distro_name> <kernel_version> <desktop_env>"
    echo "desktop_env 必须是 'gnome' 或 'kde'"
    exit 1
}

if [ $# -ne 3 ]; then
    usage
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行"
    exit 1
fi

DISTRO=$1
KERNEL=$2
DESKTOP=$3
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
# 镜像名字动态附带桌面环境名称，例如 kali_gnome_desktop_...
ROOTFS_IMG="kali_${DESKTOP}_desktop_${TIMESTAMP}.img"

echo "=========================================="
echo "⏳ 开始构建渗透测试版 Kali Linux ARM RootFS"
echo "内核版本: $KERNEL | 桌面环境: ${DESKTOP^^}"
echo "=========================================="

rm -rf rootdir || true
truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

echo "⬇️ 正在通过 Docker 提取 Kali Linux 官方 arm64 滚动版底包..."
docker pull --platform linux/arm64 kalilinux/kali-rolling:latest
docker create --name kali-temp kalilinux/kali-rolling:latest
docker export kali-temp | tar -x -C rootdir/
docker rm kali-temp

mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

rm -f rootdir/etc/resolv.conf
echo "nameserver 8.8.8.8" > rootdir/etc/resolv.conf
echo "nameserver 1.1.1.1" >> rootdir/etc/resolv.conf

export DEBIAN_FRONTEND=noninteractive

echo "📦 正在更新 Kali 系统并安装核心组件与 ${DESKTOP^^} 桌面..."
chroot rootdir apt-get update

# 🌟 核心分流逻辑：根据传入的桌面环境安装不同的包
if [ "$DESKTOP" == "gnome" ]; then
    chroot rootdir apt-get install -y --no-install-recommends \
        kali-linux-core kali-desktop-gnome gdm3 \
        systemd sudo vim wget curl tar xz-utils pciutils findutils \
        network-manager wpasupplicant dialog git gcc make libc6-dev kmod
elif [ "$DESKTOP" == "kde" ]; then
    chroot rootdir apt-get install -y --no-install-recommends \
        kali-linux-core kali-desktop-kde sddm \
        systemd sudo vim wget curl tar xz-utils pciutils findutils \
        network-manager wpasupplicant dialog git gcc make libc6-dev kmod
else
    echo "❌ 错误的桌面环境参数: $DESKTOP"
    exit 1
fi

echo "🔨 正在从高通官方源码现场编译 qrtr 服务..."
chroot rootdir bash -c "cd /tmp && git clone https://github.com/linux-msm/qrtr.git && cd qrtr && make prefix=/usr install && rm -rf /tmp/qrtr"

echo "🔨 正在扫描并注入本地内核与系统固件包..."
if ls *.deb 1> /dev/null 2>&1; then
    for pkg in *.deb; do
        dpkg-deb --fsys-tarfile "$pkg" | tar -x --keep-directory-symlink -C rootdir/
    done
    KERNEL_MODULE_DIR=$(ls rootdir/lib/modules/ | head -n 1)
    if [ -n "$KERNEL_MODULE_DIR" ]; then
        chroot rootdir /sbin/depmod -a "$KERNEL_MODULE_DIR" || true
    fi
fi

if ls *.tar.gz 1> /dev/null 2>&1; then
    for tarball in *.tar.gz; do
        tar -xz --keep-directory-symlink -f "$tarball" -C rootdir/
    done
fi

chroot rootdir bash -c "echo 'root:1234' | chpasswd"
echo "kali-sheng" > rootdir/etc/hostname

chroot rootdir useradd -m -s /bin/bash luser
chroot rootdir bash -c "echo 'luser:luser' | chpasswd"
chroot rootdir usermod -aG sudo,audio,video,input,netdev luser
echo "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" > rootdir/etc/sudoers.d/sudo-nopasswd
chmod 440 rootdir/etc/sudoers.d/sudo-nopasswd

ln -sf /lib/systemd/system/getty@.service rootdir/etc/systemd/system/getty.target.wants/getty@ttyMSM0.service
chroot rootdir systemctl enable systemd-resolved
chroot rootdir systemctl enable NetworkManager

mkdir -p rootdir/etc/udev/rules.d/
printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules

# 🌟 核心分流逻辑：根据桌面环境配置自动登录
if [ "$DESKTOP" == "gnome" ]; then
    echo "🩹 配置 GDM3 (GNOME) 自动登录..."
    chroot rootdir systemctl enable gdm3
    chroot rootdir systemctl set-default graphical.target
    mkdir -p rootdir/etc/gdm3
    printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=luser\n" > rootdir/etc/gdm3/daemon.conf
elif [ "$DESKTOP" == "kde" ]; then
    echo "🩹 配置 SDDM (KDE) 自动登录..."
    chroot rootdir systemctl enable sddm
    chroot rootdir systemctl set-default graphical.target
    mkdir -p rootdir/etc/sddm.conf.d
    printf "[Autologin]\nUser=luser\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
fi

echo "⚙️ 正在预配置高通 WiFi 固件修复与驱动适配..."
FW_DIR="rootdir/lib/firmware/ath12k/WCN7850/hw2.0"
if [ -f "$FW_DIR/board-2.bin" ]; then
    cp "$FW_DIR/board-2.bin" "$FW_DIR/board.bin"
fi

MOD_DIR="rootdir/lib/modules"
TARGET_VER="7.0.0-sm8550-gf273227fab85"
if [ -d "$MOD_DIR" ]; then
    for dir in "$MOD_DIR"/*; do
        if [ -d "$dir" ] && [ "$(basename "$dir")" != "$TARGET_VER" ]; then
            mv "$dir" "$MOD_DIR/$TARGET_VER"
            chroot rootdir /sbin/depmod -a "$TARGET_VER" || true
            break
        fi
    done
fi

cat << 'EOF' > rootdir/etc/systemd/system/qrtr-force.service
[Unit]
Description=Qualcomm IPC Router Service (QRTR)
After=network.target

[Service]
ExecStart=/usr/bin/qrtr-ns -f
Restart=always

[Install]
WantedBy=multi-user.target
EOF

chroot rootdir systemctl enable qrtr-force.service
printf "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1\n" > rootdir/etc/fstab
chroot rootdir apt-get clean

echo "🧹 正在清理后台遗留进程并安全卸载..."
fuser -k -9 -m rootdir || true
sleep 2

umount -l rootdir/dev/pts || true
umount -l rootdir/dev || true
umount -l rootdir/proc || true
umount -l rootdir/sys || true
umount -l rootdir || true
sleep 2
rm -rf rootdir

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
SPARSE_IMG="sparse_${ROOTFS_IMG}"
img2simg "$ROOTFS_IMG" "$SPARSE_IMG"
# 最终打包的名字也会带上桌面名称
7z a "kali_${DESKTOP}_desktop_${TIMESTAMP}.7z" "$SPARSE_IMG"
rm -f "$ROOTFS_IMG" "$SPARSE_IMG"

echo "🎉 Kali Linux ARM (${DESKTOP^^} 版本) 构建圆满成功！"
