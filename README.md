# NovaOS

基于 NixOS 的轻量级 Linux 游戏操作系统，专为 Xiaomi Pad 6S Pro 12.4 (SM8550, 代号 "sheng") 深度定制。

Wayland/Niri 合成器、GPU 硬件加速、精简内核 -- 将平板变为掌上 Linux 游戏主机。

属于 [Xiaomi Pad 6S Pro Linux](https://github.com/code002-2/Xiaomi-pad-6s-pro-Linux) 项目的一部分。

## 特性

- Niri 滚动平铺 Wayland 合成器
- GPU 硬件加速（Adreno 740 / Freedreno）
- 精简游戏优化内核
- Box64 / FEX 等 x86 模拟层预配置
- Steam / Lutris 游戏启动器支持
- 控制器与触屏输入优化

## 构建

```bash
sudo bash sheng-gaming-os_build.sh gaming 7.1 all niri
```

## 功能状态

参见 [主项目 Wiki](https://github.com/code002-2/Xiaomi-pad-6s-pro-Linux/wiki)

[![Telegram](https://img.shields.io/badge/Telegram-%40Pad_6S_Pro_Linux_Chat-blue?logo=telegram)](https://t.me/Pad_6S_Pro_Linux_Chat)
