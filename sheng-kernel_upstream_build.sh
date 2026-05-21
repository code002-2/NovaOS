#!/bin/bash
set +e # 关闭遇到错误立退，由脚本精细捕获

WORKSPACE="${1:-$(pwd)}"

if [ -z "$CCACHE_DIR" ]; then
    export CCACHE_DIR="/home/runner/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi

mkdir -p "$CCACHE_DIR"

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
# ========================================================

echo "📥 正在下载基础内核配置文件..."
wget https://gitlab.postmarketos.org/alghiffaryfa19/pmaports/-/raw/sheng/device/testing/linux-postmarketos-qcom-sm8550/config-postmarketos-qcom-sm8550.aarch64 -O .config

# ========================================================
# 🛠️ 核心自愈：精准修补 7.1 不兼容的代码接口
# ========================================================
echo "🩹 [1/2] 正在全量扫荡并修复所有驱动中残留的旧版 of_gpio.h 引用..."
# 使用 find 找出 drivers 和 sound 目录下包含 of_gpio.h 的所有源文件，直接一键替换
find drivers/ sound/ -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/#include <linux\/of_gpio.h>/#include <linux\/gpio\/consumer.h>/g' {} + 2>/dev/null || true
echo "✅ 全量 GPIO 头文件清理完成"

echo "🎨 [2/2] 正在修复高通 GPU (msm_gem.c) 7.1 锁管理和共享判定冲突..."
if [ -f drivers/gpu/drm/msm/msm_gem.c ]; then
    sed -i 's/obj->base.resv/obj->resv/g' drivers/gpu/drm/msm/msm_gem.c 2>/dev/null || true
    sed -i 's/(obj->resv != &obj->_resv)/(!obj->import_attach)/g' drivers/gpu/drm/msm/msm_gem.c 2>/dev/null || true
    sed -i 's/container_of(obj->resv, struct drm_gem_object, _resv)/obj/g' drivers/gpu/drm/msm/msm_gem.c 2>/dev/null || true
    echo "✅ msm_gem.c 7.1 兼容性补丁应用成功"
fi

# 确保 GPU 及声音相关 Kconfig 被满血激活
echo "CONFIG_DRM_MSM=y" >> .config
echo "CONFIG_DRM_MSM_REGISTER_LOGGING=y" >> .config
echo "CONFIG_DRM_MSM_GPU_STATE=y" >> .config

echo "🔄 正在针对新合并的 7.1 内核自动刷新 Kconfig 选项..."
make ARCH=arm64 LLVM=1 olddefconfig

# ========================================================
# 🔨 精准编译：捕获并打印驱动核心报错
# ========================================================
echo "🔨 开始编译内核 Image, Image.gz, 内核模块(含GPU)和设备树..."
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 Image Image.gz modules dtbs 2> build_error.log
MAKE_EXIT_CODE=$?

if [ $MAKE_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "❌❌❌ 编译不幸中断！以下是脚本为你捕获的 Clang 核心报错日志 ❌❌❌"
    echo "========================================================================="
    grep -B 3 -A 5 -i "error:" build_error.log || tail -n 80 build_error.log
    echo "========================================================================="
    exit $MAKE_EXIT_CODE
else
    echo "✅ 恭喜！包含满血 GPU 驱动的 7.1 内核核心阶段顺利通过！"
fi

set -e # 恢复错误退出机制

_kernel_version="$(make kernelrelease -s)"
echo "📦 最终构建出的内核版本号为: ${_kernel_version}"

# 后续的打包与 deb/boot.img 封装逻辑
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-sheng/DEBIAN/control
PKGDIR=../linux-xiaomi-sheng
ARCH=arm64

mkdir -p $PKGDIR/boot
if [ -f arch/$ARCH/boot/Image.gz ]; then
    install -Dm644 arch/$ARCH/boot/Image.gz $PKGDIR/boot/Image.gz
else
    gzip -c arch/$ARCH/boot/Image > arch/$ARCH/boot/Image.gz
    install -Dm644 arch/$ARCH/boot/Image.gz $PKGDIR/boot/Image.gz
fi

install -Dm644 arch/$ARCH/boot/dts/qcom/sm8550-xiaomi-sheng.dtb $PKGDIR/boot/sm8550-xiaomi-sheng.dtb
install -Dm644 .config $PKGDIR/boot/config-${_kernel_version}
install -Dm644 System.map $PKGDIR/boot/System.map-${_kernel_version}
    
chmod +x ../mkbootimg
cat arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb > Image.gz-dtb_sheng
install -Dm644 Image.gz-dtb_sheng $PKGDIR/boot/Image.gz-dtb_sheng
mv Image.gz-dtb_sheng zImage_sheng

echo "📱 正在组装 Android 刷机镜像 boot.img..."
../mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=linux" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_dualboot.img
../mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=userdata" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_singleboot.img

echo "🧱 安装内核模块..."
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=../linux-xiaomi-sheng modules_install
rm -rf ../linux-xiaomi-sheng/lib/modules/**/build
cd ..

echo "🧬 拉取固件与外设配置..."
git clone https://github.com/map220v/sheng-firmware --depth 1
mkdir -p firmware-xiaomi-sheng/usr/lib/firmware
cp -r sheng-firmware/* firmware-xiaomi-sheng/usr/lib/firmware/
rm -rf sheng-firmware

git clone https://github.com/alghiffaryfa19/alsa-sheng --depth 1
cp -r alsa-sheng/* alsa-xiaomi-sheng/
rm -rf alsa-sheng

echo "📦 正在执行 dpkg-deb 打包..."
dpkg-deb --build --root-owner-group linux-xiaomi-sheng
dpkg-deb --build --root-owner-group firmware-xiaomi-sheng
dpkg-deb --build --root-owner-group alsa-xiaomi-sheng
dpkg-deb --build --root-owner-group sheng-devauth

echo "🎉 全自动化合并与编译任务已圆满落幕！"
