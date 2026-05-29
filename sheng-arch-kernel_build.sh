#!/bin/bash
set -e

# ==========================================
# 环境变量与工具链配置
# ==========================================
export ARCH=arm64
export CC="ccache clang"
export CXX="ccache clang++"
export HOSTCC="ccache clang"
export HOSTCXX="ccache clang++"
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
export LLVM=1

# 如果是本地跑，没有 ccache 目录则自动设定
if [ -z "$CCACHE_DIR" ]; then
    export CCACHE_DIR="$HOME/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi
mkdir -p "$CCACHE_DIR"

OUT_DIR="../out_arch_kernel"
MOD_DIR="../out_modules"
rm -rf "$OUT_DIR" "$MOD_DIR"
mkdir -p "$OUT_DIR/boot" "$MOD_DIR"

# ==========================================
# 获取源码
# ==========================================
echo "⬇️ 正在拉取 SM8550 主线内核源码..."
if [ ! -d "linux" ]; then
    git clone https://github.com/map220v/sm8550-mainline.git --branch sheng-7.0 --depth 1 linux
fi
cd linux

# ==========================================
# 编译内核与设备树
# ==========================================
echo "⚙️ 正在配置内核..."
cp ../config-postmarketos-qcom-sm8550.aarch64 .config

echo "🔨 正在编译内核 (Image.gz & dtb)..."
make -j$(nproc) O=out ARCH=arm64 CC="ccache clang" LLVM=1

_kernel_version="$(make O=out kernelrelease -s)"
echo "✅ 内核版本: ${_kernel_version}"

# ==========================================
# 生成并打包内核模块 (Modules)
# ==========================================
echo "📦 正在安装内核模块..."
make O=out ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH="$MOD_DIR" modules_install

# 清理模块目录中的软链接（避免在其他机器上解压时路径损坏）
rm -f "$MOD_DIR/lib/modules/${_kernel_version}/build"
rm -f "$MOD_DIR/lib/modules/${_kernel_version}/source"

echo "🗜️ 正在将内核模块打包为 Arch 兼容格式..."
cd "$MOD_DIR"
tar -czvf "$OUT_DIR/sheng-modules.tar.gz" .
cd ../linux

# ==========================================
# 提取产物并生成 boot.img
# ==========================================
echo "🧩 正在合并内核与设备树..."
cp out/arch/arm64/boot/Image.gz "$OUT_DIR/boot/Image.gz"
cp out/arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb "$OUT_DIR/boot/sm8550-xiaomi-sheng.dtb"

cat "$OUT_DIR/boot/Image.gz" "$OUT_DIR/boot/sm8550-xiaomi-sheng.dtb" > "$OUT_DIR/zImage_sheng"

echo "💿 正在使用 mkbootimg 组装 Android 启动镜像..."
# 🚨 此处包含了至关重要的 rootwait 和 rw 参数，防止内核抢跑崩溃
../mkbootimg --kernel "$OUT_DIR/zImage_sheng" \
    --cmdline "root=PARTLABEL=linux rootwait rw" \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --tags_offset 0x01e00000 \
    --pagesize 4096 \
    --id \
    -o "$OUT_DIR/boot_sheng_dualboot.img"

echo "🎉 Arch Linux 内核构建与打包完成！"
ls -la "$OUT_DIR"
