#!/bin/bash
set -e

IMAGE_SIZE="4G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

usage() {
    echo "用法: $0 <server|desktop>"
    exit 1
}
[ $# -ne 1 ] && usage

VARIANT=$1
if [[ "$VARIANT" != "server" && "$VARIANT" != "desktop" ]]; then
    echo "错误: variant 必须是 server 或 desktop"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行"
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="archlinux_${VARIANT}_${TIMESTAMP}.img"

echo "=========================================="
echo "开始构建 Arch Linux RootFS ($VARIANT)"
echo "=========================================="

rm -rf rootdir || true
truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# --- 配置 Arch Linux ARM 源 ---
# 初始化 pacman 并配置为使用 Arch Linux ARM 仓库
mkdir -p rootdir/var/lib/pacman
mkdir -p rootdir/etc/pacman.d
# 预先放置一个临时的 gpg 目录，避免初始化的交互请求
mkdir -p rootdir/etc/pacman.d/gnupg

# 配置基础的 pacman.conf，允许弱签名以解决构建中的常见问题
cat > rootdir/etc/pacman.conf <<EOF
[options]
Architecture = aarch64
SigLevel = Never
[core]
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
[extra]
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
[community]
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
EOF

# 复制本地的内核 .deb 包 (虽然 Arch 可能不需要，但保留以兼容流程)
if ls *.deb 1>/dev/null 2>&1; then
    cp *.deb rootdir/tmp/
fi

# 关键步骤：静态 QEMU 模拟
# 1. 设置 binfmt 支持
if [ ! -f /proc/sys/fs/binfmt_misc/status ]; then
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
fi
update-binfmts --enable

# 2. 确保 qemu-user-static 存在
if ! command -v qemu-aarch64-static &> /dev/null; then
    apt-get update && apt-get install -y qemu-user-static
fi
cp $(which qemu-aarch64-static) rootdir/usr/bin/

# --- 核心构建步骤：pacstrap (在 chroot 环境中运行) ---
# 由于 pacstrap 原生不支持指定架构，我们将使用 arch-chroot 配合 QEMU 来完成
cat > rootdir/bootstrap.sh <<'EOF'
#!/bin/bash
# 临时使用 arm64 仓库进行初始化
echo "初始化 Pacman 密钥环..."
pacman-key --init
# 由于构建环境无网络，直接信任所有密钥（仅用于镜像构建）
pacman-key --populate archlinuxarm

echo "安装基础系统..."
pacman -Syu --noconfirm --needed base base-devel
if [ "$1" = "desktop" ]; then
    pacman -S --noconfirm --needed xorg-server xorg-xinit plasma-desktop sddm firefox
fi
EOF

chmod +x rootdir/bootstrap.sh
# 这里需要使用 qemu-user-static 来运行 aarch64 二进制
chroot rootdir /usr/bin/qemu-aarch64-static /bin/bash /bootstrap.sh $VARIANT

# 清理 QEMU 模拟器
rm -f rootdir/usr/bin/qemu-aarch64-static

# --- 执行 systemd 服务和用户配置 ---
# 这些配置是在当前宿主机上进行的，因为操作的是纯文本文件
echo "arch-${VARIANT}" > rootdir/etc/hostname

cat > rootdir/etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en*
[Network]
DHCP=yes
EOF

if [ "$VARIANT" = "desktop" ]; then
    # 启用 SDDM 并创建用户
    chroot rootdir systemctl enable sddm
    chroot rootdir useradd -m -G wheel -s /bin/bash arch
    echo "arch:arch" | chroot rootdir chpasswd
    # 添加用户到 sudoers
    echo "arch ALL=(ALL) ALL" >> rootdir/etc/sudoers
else
    # 启用 SSH 服务
    chroot rootdir systemctl enable sshd
fi

# 启用网络服务
chroot rootdir systemctl enable systemd-networkd systemd-resolved

# --- 清理和打包 ---
chroot rootdir pacman -Scc --noconfirm
rm -rf rootdir/tmp/*.deb rootdir/bootstrap.sh

umount rootdir/proc rootdir/sys rootdir/dev 2>/dev/null || true
umount rootdir || true
rm -rf rootdir

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
echo "✅ 生成镜像: $ROOTFS_IMG"
echo "🗜️ 压缩中..."
7z a "${ROOTFS_IMG}.7z" "$ROOTFS_IMG"
echo "🎉 完成！"
