#!/bin/bash
set -e

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
DEBIAN_SUITE="trixie"
DEBIAN_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"

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

DISTRO=$1
KERNEL=$2
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="paddeck_os_${TIMESTAMP}.img"

echo "=========================================="
echo "🎮 开始构建 PadDeck OS"
echo "内核版本: $KERNEL"
echo "=========================================="

rm -rf rootdir || true
truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

debootstrap --arch=arm64 "$DEBIAN_SUITE" rootdir "$DEBIAN_MIRROR"

mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

printf "deb %s %s main contrib non-free non-free-firmware\n" "$DEBIAN_MIRROR" "$DEBIAN_SUITE" > rootdir/etc/apt/sources.list
printf "deb %s %s-updates main contrib non-free non-free-firmware\n" "$DEBIAN_MIRROR" "$DEBIAN_SUITE" >> rootdir/etc/apt/sources.list
chroot rootdir apt update

# 🚨 增强：加入 python3-pyqt5 以支持激活界面运行
chroot rootdir apt install -y --no-install-recommends \
    systemd systemd-resolved sudo vim-tiny wget curl network-manager wpasupplicant dbus locales git 7zip unzip tar \
    libsdl2-2.0-0 libsdl2-mixer-2.0-0 libvpx9 steam-devices joystick python3-pyqt5

chroot rootdir bash -c "echo 'LANG=en_US.UTF-8' > /etc/default/locale"
chroot rootdir sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
chroot rootdir locale-gen en_US.UTF-8

chroot rootdir bash -c "echo -e '1234\n1234' | passwd root"
echo "paddeck-sm8550" > rootdir/etc/hostname

echo "🎮 拉取游戏图形栈与微型合成器..."
chroot rootdir apt install -y --no-install-recommends \
    gamescope lightdm pipewire pipewire-pulse wireplumber \
    libgl1-mesa-dri libglx-mesa0 libegl-mesa0 mesa-vulkan-drivers mesa-utils \
    openbox xwayland mangohud

echo "📥 注入骁龙闭源固件..."
mkdir -p rootdir/tmp/linux-fw
git clone --depth 1 --filter=blob:none --sparse https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git rootdir/tmp/linux-fw
git -C rootdir/tmp/linux-fw sparse-checkout set qcom
mkdir -p rootdir/lib/firmware/
cp -a rootdir/tmp/linux-fw/qcom rootdir/lib/firmware/
rm -rf rootdir/tmp/linux-fw

# ================= 🚨 硬件补丁区 =================
echo "🔧 正在注入小米 Pad 6S Pro (Sheng) Wi-Fi 修复补丁..."
wget -qO rootdir/tmp/firmware-sheng-wififix.deb "https://github.com/code002-2/Xiaomi-pad-6s-pro-Linux/releases/download/fix/firmware-sheng-wififix.deb"
chroot rootdir apt install -y /tmp/firmware-sheng-wififix.deb
echo "✅ Wi-Fi 补丁安装完毕！"
# =================================================

# 创建玩家账户
chroot rootdir useradd -m -s /bin/bash luser
echo "luser:luser" | chroot rootdir chpasswd
chroot rootdir usermod -aG sudo,audio,video,render,input luser

# ================= 🚨 Steam ARM64 原生注入区 =================
echo "🚀 正在植入 Valve 官方 ARM64 Steam 客户端..."

chroot rootdir bash -c "ln -sf /usr/lib/aarch64-linux-gnu/libvpx.so.9 /usr/lib/aarch64-linux-gnu/libvpx.so.6"

mkdir -p rootdir/home/luser/.local/share/Steam/package
mkdir -p rootdir/home/luser/.local/share/Steam/compatibilitytools.d
mkdir -p rootdir/home/luser/.steam
mkdir -p rootdir/home/luser/.config/MangoHud

# 📊 注入 Steam Deck 风格的性能浮窗配置 (MangoHud)
cat <<EOF > rootdir/home/luser/.config/MangoHud/MangoHud.conf
legacy_layout=false
horizontal
battery
gpu_stats
cpu_stats
ram
vram
fps
frametime
hud_no_margin
table_columns=14
frame_timing=1
EOF

wget -qO rootdir/tmp/steam_arm.zip https://client-update.steamstatic.com/bins_linuxarm64_linuxarm64.zip.f523fa87fc6b9b5435a5e7370cb0d664ef53b50b
unzip -q rootdir/tmp/steam_arm.zip -d rootdir/tmp/steam_arm_extracted
mv rootdir/tmp/steam_arm_extracted/steamrtarm64 rootdir/home/luser/.local/share/Steam/

echo "publicbeta" > rootdir/home/luser/.local/share/Steam/package/beta
chroot rootdir bash -c "ln -sf /home/luser/.local/share/Steam/linuxarm64 /home/luser/.steam/sdkarm64"

echo "📦 注入 Proton 11 ARM64 ..."
wget -qO rootdir/tmp/ARM64proton-Runtime64.tar.gz "https://github.com/code002-2/Xiaomi-pad-6s-pro-Linux/releases/download/app/ARM64proton-Runtime64.tar.gz"
tar -xzf rootdir/tmp/ARM64proton-Runtime64.tar.gz -C rootdir/home/luser/.local/share/Steam/compatibilitytools.d/

chmod -R u+rwx rootdir/home/luser/.local/share/Steam/steamrtarm64/
chroot rootdir chown -R luser:luser /home/luser/.local
chroot rootdir chown -R luser:luser /home/luser/.steam
chroot rootdir chown -R luser:luser /home/luser/.config
# ==============================================================

# ================= 🚀 OOBE 开箱引导程序内嵌区 =================
echo "🎨 正在注入 PadDeck OS 首次激活引导程序..."

# 1. 写入 Python 激活界面脚本 (单引号包裹 EOF 保证变量不被转义)
cat << 'EOF' > rootdir/usr/local/bin/paddeck-oobe.py
#!/usr/bin/env python3
import sys, os, subprocess
from PyQt5.QtWidgets import (QApplication, QWidget, QVBoxLayout, QLabel, QPushButton, QListWidget, QLineEdit, QStackedWidget)
from PyQt5.QtCore import Qt

class PadDeckOOBE(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
        self.showFullScreen()
        self.setStyleSheet("background-color: #1a1a1a; color: white; font-size: 18px;")
        
        self.stack = QStackedWidget(self)
        
        # 页面 1: Wi-Fi 连接
        self.page_wifi = QWidget()
        wifi_layout = QVBoxLayout()
        title_wifi = QLabel("连接到 Wi-Fi 网络")
        title_wifi.setAlignment(Qt.AlignCenter)
        title_wifi.setStyleSheet("font-size: 32px; font-weight: bold; margin-bottom: 20px;")
        
        self.wifi_list = QListWidget()
        self.wifi_list.setStyleSheet("background-color: #2d2d2d; border-radius: 8px; padding: 10px;")
        try:
            result = subprocess.check_output(['nmcli', '-t', '-f', 'SSID', 'dev', 'wifi']).decode('utf-8')
            ssids = list(set([line for line in result.split('\n') if line.strip()]))
            self.wifi_list.addItems(ssids)
        except:
            self.wifi_list.addItem("暂无可用网络，请稍后再试")
            
        self.pwd_input = QLineEdit()
        self.pwd_input.setPlaceholderText("请输入 Wi-Fi 密码...")
        self.pwd_input.setEchoMode(QLineEdit.Password)
        self.pwd_input.setStyleSheet("background-color: #2d2d2d; padding: 15px; border-radius: 8px;")
        
        btn_connect = QPushButton("连接并继续")
        btn_connect.setStyleSheet("background-color: #1a9fff; padding: 15px; border-radius: 8px; font-weight: bold;")
        btn_connect.clicked.connect(self.connect_wifi)
        
        wifi_layout.addWidget(title_wifi)
        wifi_layout.addWidget(self.wifi_list)
        wifi_layout.addWidget(self.pwd_input)
        wifi_layout.addWidget(btn_connect)
        self.page_wifi.setLayout(wifi_layout)
        
        # 页面 2: 欢迎界面
        self.page_welcome = QWidget()
        welcome_layout = QVBoxLayout()
        title_welcome = QLabel("🎉 欢迎来到 PadDeck OS")
        title_welcome.setAlignment(Qt.AlignCenter)
        title_welcome.setStyleSheet("font-size: 48px; font-weight: bold; color: #1a9fff;")
        
        subtitle = QLabel("您的骁龙 8 Gen 2 游戏掌机已准备就绪。")
        subtitle.setAlignment(Qt.AlignCenter)
        subtitle.setStyleSheet("font-size: 24px; color: #a0a0a0; margin-bottom: 40px;")
        
        btn_start = QPushButton("进入 Steam")
        btn_start.setStyleSheet("background-color: #1a9fff; padding: 20px; border-radius: 8px; font-size: 24px; font-weight: bold;")
        btn_start.clicked.connect(self.finish_oobe)
        
        welcome_layout.addStretch()
        welcome_layout.addWidget(title_welcome)
        welcome_layout.addWidget(subtitle)
        welcome_layout.addWidget(btn_start)
        welcome_layout.addStretch()
        self.page_welcome.setLayout(welcome_layout)
        
        self.stack.addWidget(self.page_wifi)
        self.stack.addWidget(self.page_welcome)
        
        main_layout = QVBoxLayout()
        main_layout.addWidget(self.stack)
        self.setLayout(main_layout)

    def connect_wifi(self):
        selected = self.wifi_list.currentItem()
        if selected:
            ssid = selected.text()
            pwd = self.pwd_input.text()
            if pwd:
                subprocess.Popen(['nmcli', 'dev', 'wifi', 'connect', ssid, 'password', pwd])
        self.stack.setCurrentIndex(1) # 前往欢迎页
        
    def finish_oobe(self):
        config_dir = os.path.expanduser('~/.config')
        os.makedirs(config_dir, exist_ok=True)
        with open(os.path.join(config_dir, 'oobe_done'), 'w') as f:
            f.write("done")
        QApplication.quit() # 优雅退出，交出控制权

if __name__ == '__main__':
    app = QApplication(sys.argv)
    ex = PadDeckOOBE()
    sys.exit(app.exec_())
EOF

# 2. 写入引导分流脚本 (判断是否第一次开机)
cat << 'EOF' > rootdir/usr/local/bin/paddeck-session
#!/bin/bash
# 如果是第一次开机，运行 Python OOBE 激活程序
if [ ! -f "$HOME/.config/oobe_done" ]; then
    python3 /usr/local/bin/paddeck-oobe.py
fi

# 无论激活是否刚走完，只要过了上一关，直接拉起带浮窗的 SteamOS 界面！
exec mangohud /home/luser/.local/share/Steam/steamrtarm64/steam -gamepadui -steamos3 -steampal -steamdeck
EOF

# 3. 赋予执行权限
chmod +x rootdir/usr/local/bin/paddeck-oobe.py
chmod +x rootdir/usr/local/bin/paddeck-session
# ==============================================================

chroot rootdir bash -c "echo 'ttyMSM0' >> /etc/securetty"
ln -sf /lib/systemd/system/getty@.service rootdir/etc/systemd/system/getty.target.wants/getty@ttyMSM0.service

chroot rootdir systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf rootdir/etc/resolv.conf

mkdir -p rootdir/etc/udev/rules.d/
printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules

mkdir -p rootdir/etc/lightdm/lightdm.conf.d
cat <<EOF > rootdir/etc/lightdm/lightdm.conf.d/12-autologin.conf
[Seat:*]
autologin-user=luser
autologin-user-timeout=0
user-session=gamescope-session
EOF

# 🎮 终极伪装：交由 gamescope 托管我们的分流脚本
mkdir -p rootdir/usr/share/wayland-sessions
cat <<EOF > rootdir/usr/share/wayland-sessions/gamescope-session.desktop
[Desktop Entry]
Name=PadDeck OS
Comment=PadDeck Session Wrapper
Exec=gamescope -W 3096 -H 1920 -r 144 -f -e -- /usr/local/bin/paddeck-session
Type=Application
EOF

chroot rootdir systemctl enable lightdm
chroot rootdir systemctl set-default graphical.target

printf "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1\n" > rootdir/etc/fstab

chroot rootdir apt clean
chroot rootdir rm -rf /tmp/*

umount rootdir/dev/pts || true
umount rootdir/dev || true
umount rootdir/proc || true
umount rootdir/sys || true
umount rootdir || true
rm -rf rootdir

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"

echo "✅ 镜像生成完成: $ROOTFS_IMG"
7z a "paddeck_os_sm8550_${TIMESTAMP}.7z" "$ROOTFS_IMG"
rm -f "$ROOTFS_IMG"

echo "🎉 PadDeck OS 终极版构建成功！"
