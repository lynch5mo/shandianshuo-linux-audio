# 给官方的一屏反馈稿

> 可直接粘贴到应用内「常见问题 / 反馈」或邮件。完整说明见仓库 `ISSUE.md`。

---

**版本**：闪电说 v0.7.7 Linux AppImage（由 v0.7.5 自动升级）
**系统**：Omarchy/Arch（Hyprland，Wayland + Xwayland），pipewire 1.6.9 + pipewire-alsa + wireplumber 0.5.18，alsa-lib 1.2.16
**现象**：按录音键提示「检查麦克风」，随后改为「未检测到音频输入设备」；录音从未成功过。v0.7.5 正常。

**问题 1（回归）：自动选设备直开 ALSA 硬件节点**

```
[Audio] Resolved device: "HDA Intel PCH, CS4208 Analog" (raw: "front:CARD=PCH,DEV=0", mode: auto)
ERROR [Audio] Thread error: The requested device is no longer available. For example, it has been unplugged.
```

v0.7.5 的自动选择是 `selected 'default'`（正确）；v0.7.7 改成把 PipeWire 音源映射成
`front:CARD=...,DEV=0` / `plughw:CARD=...,DEV=...`。在 PipeWire 会话中采集 PCM 被 PipeWire 独占，
直开硬件节点必然 `EBUSY`（`arecord -D hw:1,0` 也一样）。建议：自动选择时逐个试开，`EBUSY`/`ENXIO`
回退到 ALSA `default`（或直接用 PipeWire/PulseAudio API）。

**问题 2：AppImage 打包的旧 libpipewire 遮蔽系统库**

把 `audio_device` 改成 `default` 后仍失败：

```
ERROR [Audio] Thread error: ALSA function 'snd_pcm_open' failed with error 'No such device or address (6)'
```

原因：AppImage 的 `usr/lib` 带了一份 2025-08-05 的 `libpipewire-0.3.so.0`，经 `LD_LIBRARY_PATH`
遮蔽系统 1.6.9，导致系统的 `/usr/lib/alsa-lib/libasound_module_pcm_pipewire.so` 加载失败：

```
Cannot open shared library libasound_module_pcm_pipewire.so (undefined symbol: pw_log_topic_register)
```

alsa-lib 把插件加载失败折算成 `ENXIO`，于是应用认为「没有音频输入设备」。
建议：AppImage 不要打包 `libpipewire-0.3.so.0`（同理 `libwayland-client.so.0`）。

**问题 3：粘贴阶段只认 xclip**

```
[linux] Tool chain: type=Some(Wtype), clip=None (X11), paste=Some(Wtype)
ERROR [Inject] voice input paste failed: No clipboard tool available.
      Install wl-copy/wl-paste (Wayland) or xclip (X11).
```

应用以 `GDK_BACKEND=x11` 跑在 Xwayland，目标被判为 X11，只找 `xclip`；系统虽装了 `wl-clipboard`
也不会回退。且探测结果缓存到首次粘贴后，装完工具必须重启应用。建议：Wayland 会话优先
`wl-copy`/`wl-paste`，`xclip` 作回退，并在 `PATH` 变化后重新探测。

**用户侧临时绕过（已实测可正常录音+上屏，供官方参考/如需先给用户答复）**

1. `~/.config/shandianshuo/config.json`：`"audio_device": "default"`
2. 用一个包装脚本启动 AppImage：
   `LD_PRELOAD=/usr/lib/libpipewire-0.3.so.0:$HOME/Applications/shandianshuo.AppImage`
3. 安装 `xclip` 后重启应用

细节与复现命令：https://github.com/lynch5mo/shandianshuo-linux-audio
