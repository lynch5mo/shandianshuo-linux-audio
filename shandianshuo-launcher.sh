#!/usr/bin/env bash
# 启动器：用系统库遮蔽 AppImage 自带的旧库
#
# 一、libpipewire（v0.7.7 起必加，否则「检查麦克风 / 未检测到音频输入设备」）
#
#   现象：按右 Alt 录音时提示设备错误，日志里是
#     [Audio] Resolved device: "Default ALSA Output (currently PipeWire Media Server)" (raw: "default")
#     ERROR [Audio] Thread error: ALSA function 'snd_pcm_open' failed with error
#       'No such device or address (6)'
#
#   原因：这个 AppImage 的 usr/lib 里打包了一份 2025-08-05 的 libpipewire-0.3.so.0，
#     AppImage 运行时把它塞进 LD_LIBRARY_PATH，遮蔽系统 pipewire 1.6.9。
#     系统里的 alsa 插件 /usr/lib/alsa-lib/libasound_module_pcm_pipewire.so
#     需要新版符号，旧库加载失败：
#       "Cannot open shared library libasound_module_pcm_pipewire.so
#        (undefined symbol: pw_log_topic_register)"
#     alsa-lib 把插件加载失败折算成 ENXIO，于是 cpal 报 snd_pcm_open 失败。
#     → 任何走 PipeWire 的 ALSA 设备（default / pipewire）在 App 里都打不开。
#
#   注意：App 直接开硬件设备（front:CARD=PCH,DEV=0、hw:1,0）也不行 ——
#     PipeWire 已经占用 CS4208 的采集 PCM，别的进程直开 hw 一律 EBUSY。
#     所以 config.json 里的 "audio_device" 要用 "default"（经 pipewire-alsa 共享麦克风），
#     配合下面的 LD_PRELOAD 才能出声。
#
# 二、libwayland-client（v0.7.5 时期的问题，0.7.7 已不打包，保留以兼容旧版）
#
#   旧版自带旧 libwayland-client.so.0，遮蔽系统 wayland 1.26，
#   Mesa libEGL 初始化失败（EGL_BAD_PARAMETER），WebKit 子进程启动即 abort，
#   主窗口只剩透明框。预加载系统新版即可。
# 三、关闭/最小化按钮（hide-on-minimize.so，可选但强烈建议）
#
#   现象：在 Hyprland/Sway/Niri 上点标题栏「关闭」窗口纹丝不动，日志却是
#     INFO Main window minimized on Linux tray fallback
#   原因：关闭 = Tauri 的 window.minimize() → gtk_window_iconify()，GTK 在 X11 上把
#     最小化翻成 ICCCM WM_CHANGE_STATE(IconicState)，Hyprland 只对原生 Wayland 客户端
#     实现最小化（xdg_toplevel.set_minimized），对 Xwayland 窗口的 iconify 请求直接忽略。
#     而应用必须 GDK_BACKEND=x11（浮窗定位），绕不过去。
#   修法：LD_PRELOAD 一个小垫片，把 gtk_window_iconify 换成 gtk_widget_hide ——
#     窗口隐藏、应用继续后台常驻、全局快捷键照常工作，托盘「显示闪电说」能重新显示。
#   源码见仓库 shandianshuo-hide-on-minimize.c，编译产物装到
#     ~/.local/lib/shandianshuo/libshandianshuo-hide-on-minimize.so
#   删掉本行即可回到原行为（窗口关不掉）。
exec env \
  LD_PRELOAD=/usr/lib/libpipewire-0.3.so.0:/usr/lib/libwayland-client.so.0:$HOME/.local/lib/shandianshuo/libshandianshuo-hide-on-minimize.so \
  "${SHANDIANSHUO_APPIMAGE:-$HOME/Applications/shandianshuo.AppImage}" "$@"
