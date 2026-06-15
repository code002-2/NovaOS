#!/bin/bash
set -e

# ==========================================
# 1. 编译环境配置
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
echo "📥 正在拉取内核源码..."
git clone https://github.com/code002-2/sm8550-mainline.git --branch sheng-mainline --depth 1 linux
cd linux

# ==========================================
# 3. 配置注入
# ==========================================
echo "⚙️ 正在应用自动生成的底座配置..."

# 1. 复制你自己的干净配置作为基础底座
cp ../sm8550.config .config

echo "🔍 正在从 postmarketos 提取配置..."
grep -E '^CONFIG_.*(QCOM|MSM|SM8550|XIAOMI|ADRENO)=' ../config-postmarketos-qcom-sm8550.aarch64.txt > qcom_extras.config || true

# 3. 防缩水机制：将提取出来的专有驱动强制转为内置 (=y)
sed -i 's/=m/=y/g' qcom_extras.config

# 4. 将提取出的专有驱动追加入你的底座配置中
cat qcom_extras.config >> .config

# 5. 硬编码保底驱动与冲突屏蔽
{
    echo "# ---- 核心亮机保底驱动 (防止跨版本丢失) ----"
    echo "CONFIG_SCSI_UFS_QCOM=y"
    echo "CONFIG_PHY_QCOM_QMP_UFS=y"
    echo "CONFIG_DRM_MSM=y"
    echo "CONFIG_DRM_MSM_DPU=y"
    echo "CONFIG_DRM_PANEL_XIAOMI_SHENG=y"
    echo "CONFIG_QCOM_SPMI_PMIC=y"
    echo "CONFIG_USB_DWC3_QCOM=y"
    
    echo "# ---- 屏蔽冲突项 (KVM 与 第三方网卡) ----"
    echo "# CONFIG_KVM is not set"
    echo "# CONFIG_KVM_ARM_VGIC_V3 is not set"
    echo "# CONFIG_KVM_ARM_VGIC_V2 is not set"
    echo "# CONFIG_ARM64_VIRT is not set"
    echo "# CONFIG_WLAN_VENDOR_INTEL is not set"
    echo "# CONFIG_IWLWIFI is not set"
    echo "# CONFIG_WLAN_VENDOR_REALTEK is not set"
    echo "# CONFIG_WLAN_VENDOR_MEDIATEK is not set"
    echo "# CONFIG_WLAN_VENDOR_BROADCOM is not set"
} >> .config

# 6. 使用 olddefconfig 安全融合并自动补全依赖
echo "🔄 正在自动融合配置..."
make ARCH=arm64 olddefconfig

# ==========================================
# 4. 彻底清空 KVM 冲突源
# ==========================================
echo "🧹 正在清理 KVM 冲突文件..."
find arch/arm64/kvm/ -name "*.c" -type f -delete
find arch/arm64/kvm/ -name "*.h" -type f -delete
echo "obj- := empty.o" > arch/arm64/kvm/Makefile

# ==========================================
# 5. 执行编译
# ==========================================
echo "🔨 开始极速编译..."

# 编译核心 Image
make -j$(nproc) ARCH=arm64 LLVM=1 Image

# 压缩内核镜像
echo "🗜️ 正在压缩内核镜像..."
gzip -c arch/arm64/boot/Image > arch/arm64/boot/Image.gz

# 强制编译设备树 (使用 -f 忽略重复节点错误)
make -j$(nproc) ARCH=arm64 LLVM=1 DTC_FLAGS="-f" qcom/sm8550-xiaomi-sheng.dtb

# 编译残余模块
make -j$(nproc) ARCH=arm64 LLVM=1 modules

# ==========================================
# 6. 产物体检
# ==========================================
echo "📊 核心产物大小检查："
ls -lh arch/arm64/boot/Image arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb

if [ ! -f "arch/arm64/boot/Image.gz" ]; then
    echo "❌ 严重错误：Image.gz 依然不存在！"
    exit 1
fi

# ==========================================
# 7. 打包内核镜像 (boot.img)
# ==========================================
echo "📦 正在生成 boot.img..."
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

cd ..

echo "🔧 正在进行 UsrMerge 路径手术 (确保 Arch/Fedora 兼容性)..."

# 对所有可能包含 /lib 目录的包进行自动化修正
for pkg in firmware-xiaomi-sheng alsa-xiaomi-sheng sensor; do
    if [ -d "$pkg/lib" ]; then
        echo "✅ 正在将 $pkg 中的 /lib 迁移至 /usr/lib"
        mkdir -p "$pkg/usr"
        mv "$pkg/lib" "$pkg/usr/"
    fi
done

echo "📦 开始打包现代化结构的 deb 文件..."
# 确保所有包按照统一结构打包
dpkg-deb --build --root-owner-group linux-xiaomi-sheng
dpkg-deb --build --root-owner-group firmware-xiaomi-sheng
dpkg-deb --build --root-owner-group alsa-xiaomi-sheng
dpkg-deb --build --root-owner-group sheng-devauth
dpkg-deb --build --root-owner-group sensor

echo "🎉 所有任务圆满完成！恭喜！"
