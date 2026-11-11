#!/usr/bin/env bash
# 闪电说 (Shandianshuo) AppImage 启动包装脚本
#
# 作用：用系统库遮蔽 AppImage 自带的旧库。两个问题、两段说明。
#
# ── 1. libpipewire：否则「检查麦克风 / 未检测到音频输入设备」 ──────────────
#
#   现象：按快捷键录音报设备错误，日志：
#     [Audio] Resolved device: "Default ALSA Output (currently PipeWire Media Server)" (raw: "default")
#     ERROR [Audio] Thread error: ALSA function 'snd_pcm_open' failed with error
#           'No such device or address (6)'
#
#   原因：AppImage 的 usr/lib 里打包了一份旧 libpipewire-0.3.so.0，运行时经
#     LD_LIBRARY_PATH 遮蔽系统库（1.6.x）。系统的 alsa 插件
#     /usr/lib/alsa-lib/libasound_module_pcm_pipewire.so 需要新符号，加载失败：
#       Cannot open shared library libasound_module_pcm_pipewire.so
#       (undefined symbol: pw_log_topic_register)
#     alsa-lib 把插件加载失败折算成 ENXIO → cpal 报 snd_pcm_open 失败
#     → 任何走 PipeWire 的 ALSA 设备（default）都打不开。
#
#   注意：直接开硬件节点（front:CARD=...,DEV=0 / hw:1,0 / plughw:...）也不行，
#     PipeWire 已独占该 PCM，其它进程一律 EBUSY。所以 config.json 的
#     "audio_device" 必须是 "default"（经 pipewire-alsa 共享麦克风）。
#
# ── 2. libwayland-client：旧版（v0.7.5）透明窗口问题，保留以兼容回退 ────────
#
#   旧版 AppImage 自带旧 libwayland-client.so.0，遮蔽系统 wayland 1.26，
#   Mesa libEGL 初始化失败（EGL_BAD_PARAMETER），WebKit 子进程启动即 abort，
#   主窗口只剩透明框。预加载系统新版即可。
#
# 安装：放到 ~/.local/bin/shandianshuo 并 chmod +x，
#       再把 .desktop（含 ~/.config/autostart/）的 Exec 指向它。
exec env \
  LD_PRELOAD=/usr/lib/libpipewire-0.3.so.0:/usr/lib/libwayland-client.so.0 \
  "${SHANDIANSHUO_APPIMAGE:-$HOME/Applications/shandianshuo.AppImage}" "$@"
