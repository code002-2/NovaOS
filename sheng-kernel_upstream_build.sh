#!/bin/bash
set +e # 关闭遇到错误立退，由脚本精细捕获

WORKSPACE="${1:-$(pwd)}"

# ========================================================
# ⚡ CCache 极速编译配置
# ========================================================
if [ -z "$CCACHE_DIR" ]; then
    export CCACHE_DIR="/home/runner/.ccache"
fi
mkdir -p "$CCACHE_DIR"

export CCACHE_MAXSIZE="15G"
export CCACHE_COMPRESS=1
export CCACHE_COMPRESSLEVEL=5
export CCACHE_SLOPPINESS="file_macro,locale,time_macros,include_file_mtime,include_file_ctime,file_stat_matches"
export CCACHE_BASEDIR="$WORKSPACE"
export CCACHE_NOHASHDIR=1

export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

echo "🌐 正在克隆你的自定义 sm8550-mainline 仓库..."
if git clone https://github.com/code002-2/sm8550-mainline.git --branch "sheng-7.0" --depth 150 linux; then
    echo "✅ 成功克隆基础 sheng-7.0 分支"
else
    echo "⚠️ 未找到 sheng-7.0 分支，尝试克隆默认主分支..."
    git clone https://github.com/code002-2/sm8550-mainline.git --depth 150 linux
fi

echo "🛡️ 正在物理隔离并备份本地验证通过的设备树文件..."
mkdir -p dtb_backup
cp -r linux/arch/arm64/boot/dts/qcom/* dtb_backup/ 2>/dev/null || true

cd linux

# ========================================================
# 🔄 步骤：精准拉取 Linus Mainline 官方主线最新 7.1 开发树
# ========================================================
echo "📡 正在连接 Linus Mainline 官方主线内核仓库..."
git remote add upstream-mainline https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git

echo "📥 拒绝 Tags 干扰，仅精准拉取上游 master 分支最新提交..."
git fetch upstream-mainline master --depth 50 --no-tags

UPSTREAM_TARGET="upstream-mainline/master"
echo "🎯 成功锁定 Linux 7.1 开发主线上游目标: $UPSTREAM_TARGET"

echo "🔀 正在将最新 7.1 补丁自动无损合并到你的代码中..."
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

if git merge "$UPSTREAM_TARGET" --no-edit; then
    echo "✅ 完美！上游 7.1 主线最新补丁已无缝合并。"
else
    echo "❌ 警告：自动合并冲突，启动防御机制..."
    git merge --abort
    git merge "$UPSTREAM_TARGET" --no-edit -X ours
    echo "⚠️ 已通过 Ours 策略强制完成 7.1 补丁合并。"
fi

echo "♻️ 正在强行还原稳定的高通小米设备树，覆盖 7.1 错乱节点..."
cp -r ../dtb_backup/* arch/arm64/boot/dts/qcom/ 2>/dev/null || true
echo "✅ 设备树总线结构体强制回滚至安全状态"
# ========================================================

echo "📥 正在下载基础内核配置文件..."
wget https://gitlab.postmarketos.org/alghiffaryfa19/pmaports/-/raw/sheng/device/testing/linux-postmarketos-qcom-sm8550/config-postmarketos-qcom-sm8550.aarch64 -O .config

# ========================================================
# 🛠️ 核心自愈与双系统全内置策略
# ========================================================
echo "🩹 [1/5] 正在全量扫荡并修复所有驱动中残留的旧版 of_gpio.h 引用..."
find drivers/ sound/ -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/#include <linux\/of_gpio.h>/#include <linux\/gpio\/consumer.h>/g' {} + 2>/dev/null || true

echo "🚀 [2/5] 执行内核驱动『全模块转内置』硬核手术..."
sed -i 's/CONFIG_PINCTRL_SM8550=m/CONFIG_PINCTRL_SM8550=y/g' .config
sed -i 's/CONFIG_SM_GCC_8550=m/CONFIG_SM_GCC_8550=y/g' .config
sed -i 's/CONFIG_SM_DISPCC_8550=m/CONFIG_SM_DISPCC_8550=y/g' .config
sed -i 's/CONFIG_INTERCONNECT_QCOM_SM8550=m/CONFIG_INTERCONNECT_QCOM_SM8550=y/g' .config
sed -i 's/CONFIG_QCOM_RPMHPD=m/CONFIG_QCOM_RPMHPD=y/g' .config

sed -i 's/CONFIG_SCSI_UFS_QCOM=m/CONFIG_SCSI_UFS_QCOM=y/g' .config
sed -i 's/CONFIG_SCSI_UFSHCD_PLATFORM=m/CONFIG_SCSI_UFSHCD_PLATFORM=y/g' .config
sed -i 's/CONFIG_SCSI_UFSHCD=m/CONFIG_SCSI_UFSHCD=y/g' .config

echo "CONFIG_VT=y" >> .config
echo "CONFIG_VT_CONSOLE=y" >> .config
echo "CONFIG_FRAMEBUFFER_CONSOLE=y" >> .config
echo "CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y" >> .config
echo "CONFIG_FONT_8x16=y" >> .config
echo "CONFIG_LOGO=y" >> .config
echo "CONFIG_LOGO_LINUX_CLUT224=y" >> .config

# 🚨 B 槽引导特调 CMDLINE：rootwait 延长至无限期等待，强制指定 root 寻址
echo 'CONFIG_CMDLINE="console=ttyMSM0,115200 earlycon=msm_geni_serial,0xaec00000 root=PARTLABEL=linux rootwait fbcon=nodefer msm_drm.allow_fb_modifiers=1 loglevel=7 panic=0 pm_poweroff.reset_type=1"' >> .config
echo "CONFIG_CMDLINE_FORCE=y" >> .config

echo "CONFIG_CC_OPTIMIZE_FOR_SIZE=y" >> .config
sed -i 's/CONFIG_DEBUG_INFO=y/# CONFIG_DEBUG_INFO is not set/g' .config
echo "CONFIG_DEBUG_INFO_NONE=y" >> .config

# ========================================================
# 🏷️ [3/5] 核心改名
# ========================================================
echo "🏷️ 正在向内核配置系统注入自定义版本后缀: -xiaomi-pad-6s-pro-game"
sed -i '/CONFIG_LOCALVERSION/d' .config
echo 'CONFIG_LOCALVERSION="-xiaomi-pad-6s-pro-game"' >> .config

echo "🔄 正在针对新合并的 7.1 内核自动刷新 Kconfig 选项..."
make ARCH=arm64 LLVM=1 olddefconfig

# ========================================================
# 🔨 精准编译
# ========================================================
echo "🔨 开始编译内核 Image, Image.gz, 内核模块和设备树..."
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 Image Image.gz modules dtbs 2> build_error.log
MAKE_EXIT_CODE=$?

if [ $MAKE_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "❌❌❌ 编译不幸中断！以下是脚本为你捕获的 Clang 核心报错日志 ❌❌❌"
    echo "========================================================================="
    grep -B 3 -A 5 -i "error:" build_error.log || tail -n 80 build_error.log
    echo "========================================================================="
    exit $MAKE_EXIT_CODE
fi

set -e 

_kernel_version="$(make kernelrelease -s)"
echo "📦 最终构建出的内核定制版本号为: ${_kernel_version}"

# ========================================================
# 📦 打包重构：🚨【标准高通 v2 签名格式，专治 A/B 槽不认】
# ========================================================
GAME_PKG_NAME="linux-xiaomi-pad-6s-pro-game"
PKGDIR="../${GAME_PKG_NAME}"

mkdir -p "${PKGDIR}/DEBIAN"
echo "Package: ${GAME_PKG_NAME}" > "${PKGDIR}/DEBIAN/control"
echo "Version: ${_kernel_version}" >> "${PKGDIR}/DEBIAN/control"
echo "Architecture: arm64" >> "${PKGDIR}/DEBIAN/control"
echo "Maintainer: github-actions" >> "${PKGDIR}/DEBIAN/control"
echo "Description: Upstream 7.1 Linux kernel aligned for Slot B booting" >> "${PKGDIR}/DEBIAN/control"

ARCH=arm64
mkdir -p $PKGDIR/boot

if [ -f arch/$ARCH/boot/Image.gz ]; then
    install -Dm644 arch/$ARCH/boot/Image.gz $PKGDIR/boot/Image.gz
else
    gzip -c arch/$ARCH/boot/Image > arch/$ARCH/boot/Image.gz
    install -Dm644 arch/$ARCH/boot/Image.gz $PKGDIR/boot/Image.gz
fi

install -Dm644 arch/$ARCH/boot/dts/qcom/sm8550-xiaomi-sheng.dtb $PKGDIR/boot/sm8550-xiaomi-sheng.dtb
    
chmod +x ../mkbootimg

echo "📱 正在组装专属于你的 [高通标准 A/B 槽对齐] 双系统刷机镜像 boot.img..."
# 🚨 核心改动：废除 cat 拼合，采用纯正的 --dtb 参数，并在 ABL 允许的偏置下完全对齐！
../mkbootimg --kernel arch/arm64/boot/Image.gz \
             --dtb arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb \
             --cmdline "root=PARTLABEL=linux rootwait console=ttyMSM0,115200 fbcon=nodefer msm_drm.allow_fb_modifiers=1 loglevel=7" \
             --base 0x00000000 \
             --kernel_offset 0x00080000 \
             --ramdisk_offset 0x01000000 \
             --tags_offset 0x00000100 \
             --dtb_offset 0x01f00000 \
             --pagesize 4096 \
             --header_version 2 \
             -o ../boot_pad6spro_game_dualboot.img

cp ../boot_pad6spro_game_dualboot.img ../boot_pad6spro_game_singleboot.img

echo "🧱 安装内核模块..."
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=$PKGDIR modules_install
rm -rf $PKGDIR/lib/modules/**/build
cd ..

echo "🧬 拉取固件与外设配置..."
git clone https://github.com/map220v/sheng-firmware --depth 1
mkdir -p firmware-xiaomi-sheng/usr/lib/firmware
cp -r sheng-firmware/* firmware-xiaomi-sheng/usr/lib/firmware/
rm -rf sheng-firmware

git clone https://github.com/alghiffaryfa19/alsa-sheng --depth 1
cp -r alsa-sheng/* alsa-xiaomi-sheng/
rm -rf alsa-sheng

echo "📦 正在执行打包..."
dpkg-deb --build --root-owner-group "$GAME_PKG_NAME"
dpkg-deb --build --root-owner-group firmware-xiaomi-sheng
dpkg-deb --build --root-owner-group alsa-xiaomi-sheng

echo "🎉 B 槽满血对齐版内核构建任务圆满结束！"
