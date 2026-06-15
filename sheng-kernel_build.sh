#!/bin/bash
set -e

# ==========================================
# 1. 环境准备
# ==========================================
export CCACHE_DIR="/home/runner/.ccache"
export CCACHE_MAXSIZE="10G"
mkdir -p "$CCACHE_DIR"
export CC="ccache clang"
export CXX="ccache clang++"
export LLVM=1
export ARCH=arm64

# ==========================================
# 2. 拉取源码
# ==========================================
git clone https://github.com/code002-2/sm8550-mainline.git --branch sheng-mainline --depth 1 linux
cd linux

# ==========================================
# 3. 彻底跳过 kconfig 交互 (核弹级覆盖)
# ==========================================
echo "⚙️ 正在应用并强行补全配置..."

# A. 使用内核默认 defconfig 建立基座 (这步绝对不会报错)
make ARCH=arm64 defconfig

# B. 将你的底板内容注入到底座中
# 我们直接用 sed 批量修改或追加关键选项，不再调用 make oldconfig
cp ../config-postmarketos-qcom-sm8550.aarch64 .config

# C. 强制开启内核必须的编译器开关，解决 Error in reading
echo "CONFIG_COMPAT=y" >> .config
echo "CONFIG_ARM64_BTI=y" >> .config
echo "CONFIG_ARM64_MTE=y" >> .config
echo "CONFIG_LTO_NONE=y" >> .config
echo "CONFIG_PAGE_SIZE_4KB=y" >> .config

# D. 釜底抽薪：彻底删除所有会导致 duplicate_node_names 的设备树源文件
find arch/arm64/boot/dts/qcom/ -name "hamoa*.dts" -o -name "ipq*.dts" -o -name "hamoa*.dtb" -o -name "ipq*.dtb" | xargs rm -f
sed -i '/hamoa/d' arch/arm64/boot/dts/qcom/Makefile
sed -i '/ipq/d' arch/arm64/boot/dts/qcom/Makefile

# ==========================================
# 🛠️ 终极止血：将 KVM 变成一个“空壳”
# ==========================================
echo "⚙️ 正在应用配置并屏蔽 KVM 编译..."

cp ../config-postmarketos-qcom-sm8550.aarch64.txt .config

# 1. 禁用 KVM 配置，确保 Makefile 不会尝试去编译那些会导致重定义的文件
{
    echo "# CONFIG_KVM is not set"
    echo "# CONFIG_KVM_ARM_VGIC_V3 is not set"
    echo "# CONFIG_KVM_ARM_VGIC_V2 is not set"
    echo "# CONFIG_ARM64_VIRT is not set"
} >> .config

# 2. 关键修复：不要删除 kvm 目录，而是清空它！
# 这样 make 还能找到 Kconfig 文件，但里面的代码全是空的，不会触发任何报错
find arch/arm64/kvm/ -name "*.c" -type f -delete
find arch/arm64/kvm/ -name "*.h" -type f -delete

# 3. 如果 KVM 目录下还有 Makefile，清空它，让它什么都不编译
echo "obj- := empty.o" > arch/arm64/kvm/Makefile

# 4. 执行 alldefconfig 更新依赖
make ARCH=arm64 alldefconfig

# ==========================================
# 4. 执行不带交互的编译
# ==========================================
echo "🔨 开始极速编译..."

# 执行 prepare 确保生成的配置生效
make ARCH=arm64 LLVM=1 prepare

# 使用 --silent 静默编译，并只构建目标 Image 和 你的设备树
make ARCH=arm64 CC="ccache clang" LLVM=1 Image
make -j$(nproc) ARCH=arm64 LLVM=1 arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb
make -j$(nproc) ARCH=arm64 LLVM=1 modules

# ==========================================
# 5. 打包产物 (保持不变)
# ==========================================
_kernel_version="$(make kernelrelease -s)"
PKGDIR=../linux-xiaomi-sheng
mkdir -p $PKGDIR/boot

install -Dm644 arch/arm64/boot/Image.gz $PKGDIR/boot/Image.gz
install -Dm644 arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb $PKGDIR/boot/sm8550-xiaomi-sheng.dtb
install -Dm644 .config $PKGDIR/boot/config-${_kernel_version}

chmod +x ../mkbootimg
cat arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb > Image.gz-dtb_sheng
mv Image.gz-dtb_sheng zImage_sheng

../mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=linux rootwait rw" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_dualboot.img
../mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=userdata rootwait rw" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_singleboot.img

echo "🎉 终极通用版内核打包圆满完成！"
