# [Linux] v0.7.7 无法录音：自动选择会直开 ALSA 硬件节点（EBUSY），且 AppImage 自带的旧 libpipewire 使 PipeWire 设备打不开（ENXIO）

## 环境

| 项 | 值 |
|---|---|
| 发行版 | Omarchy（Arch 系），Hyprland（Wayland + Xwayland） |
| 内核 | 7.2.15-1-omarchy |
| pipewire | 1:1.6.9-1 / pipewire-alsa 1:1.6.9-1 |
| wireplumber | 0.5.18-1 |
| alsa-lib | 1.2.16.1-1 |
| 硬件 | MacBook8,1（Early 2015 12"），声卡 HDA Intel PCH / CS4208 |
| 应用 | 闪电说 v0.7.7 AppImage（由 v0.7.5 自动升级） |

## 复现步骤

1. 在任意 PipeWire 桌面（Arch/Omarchy、Fedora、Ubuntu 22.04+）安装并运行 v0.7.7 AppImage。
2. 不改任何设置，按录音快捷键说一句话。
3. 实际：提示「检查麦克风」，日志如下（`~/.config/shandianshuo/logs/shandianshuo.<date>.log`）：

```
[Audio] Resolved device: "HDA Intel PCH, CS4208 Analog" (raw: "front:CARD=PCH,DEV=0", mode: auto)
ERROR [Audio] Thread error: The requested device is no longer available. For example, it has been unplugged.
WARN  [Recording] AudioThread unresponsive, recreating
ERROR [RecordingGateway] Failed to start recording: AudioThread unresponsive
INFO  [Notification] Showing notification: device-error
```

4. 把 `~/.config/shandianshuo/config.json` 的 `"audio_device"` 改成 `"default"` 后重试，错误变成：

```
[Audio] Resolved device: "Default ALSA Output (currently PipeWire Media Server)" (raw: "default", mode: fixed)
ERROR [Audio] Thread error: A backend-specific error has occurred:
      ALSA function 'snd_pcm_open' failed with error 'No such device or address (6)'
```

界面提示「未检测到音频输入设备」。

5. 期望行为：与 v0.7.5 一致 —— 自动选中 `default`，直接可用：

```
[v0.7.5] INFO [DeviceCache] Pre-warmed: selected 'default'
```

## 根因分析

### A. 自动选设备从 `default` 回归成 ALSA 硬件节点

v0.7.7 的设备解析把 PipeWire 音源映射成 ALSA 硬件节点（日志/字符串里可见
`plughw:CARD=,DEV=`、`node.name`、`@DEFAULT_AUDIO_SOURCE@`、`wpctl get-default-source` 等探测），
最后返回 `front:CARD=PCH,DEV=0`。在 PipeWire 会话中采集 PCM 由 PipeWire 独占：

```bash
arecord -D front:CARD=PCH,DEV=0 ...   # 设备或资源忙 (EBUSY)
arecord -D hw:1,0 ...                 # 设备或资源忙 (EBUSY)
arecord -D default ...                # OK（走 pipewire-alsa）
pactl suspend-source <id> 1           # 让 PipeWire 释放设备后 hw:1,0 又能开 → 证明不是权限问题
```

cpal 把 `EBUSY` 折算成 `DeviceNotAvailable`（“设备已拔出”），于是提示「检查麦克风」。

### B. AppImage 打包的旧 libpipewire 让 pipewire-alsa 插件加载失败

AppImage 的 `usr/lib` 里有一份 2025-08-05 的 `libpipewire-0.3.so.0`（922 KB），运行时进入
`LD_LIBRARY_PATH`，遮蔽系统 1.6.9（847 KB）。系统的
`/usr/lib/alsa-lib/libasound_module_pcm_pipewire.so` 需要新符号，dlopen 失败：

```
ALSA lib dlmisc.c:339:(snd_dlobj_cache_get0) [error.core] Cannot open shared library
libasound_module_pcm_pipewire.so (undefined symbol: pw_log_topic_register)
```

alsa-lib 将插件加载失败折算成 `-ENXIO`，所以应用里连 `default` 都打不开，
表现为「未检测到音频输入设备」。

最小复现（不需要启动应用）：

```bash
./shandianshuo.AppImage --appimage-extract
gcc -o /tmp/t -x c - -lasound <<'EOF'
#include <alsa/asoundlib.h>
#include <stdio.h>
int main(void){snd_pcm_t*p;int e=snd_pcm_open(&p,"default",SND_PCM_STREAM_CAPTURE,0);
printf("%s\n",e?snd_strerror(e):"OK");return 0;}
EOF
/tmp/t                                               # OK
LD_LIBRARY_PATH=squashfs-root/usr/lib /tmp/t         # No such device or address (ENXIO)
```

### C.（顺带）粘贴阶段缺 xclip

录音/识别成功后，上屏失败：

```
[linux] Tool chain: type=Some(Wtype), clip=None (X11), paste=Some(Wtype)
ERROR [Inject] voice input paste failed: No clipboard tool available.
      Install wl-copy/wl-paste (Wayland) or xclip (X11).
```

应用以 `GDK_BACKEND=x11` 运行在 Xwayland（浮窗定位依赖），目标被判为 X11，只找 `xclip`；
即使系统已装 `wl-clipboard` 也不会回退。且该探测结果会在首次粘贴后缓存，装完工具必须重启应用。

## 建议修复

1. **不要直接打开 ALSA 硬件节点**：PipeWire/PulseAudio 会话里 `hw:`/`plughw:`/`front:` 必定 `EBUSY`。
   优先 PipeWire/PulseAudio API，或 ALSA 的 `default` / `pipewire` / `pulse`。
2. **自动选设备加可用性探测**：逐个 `snd_pcm_open` 试开，`EBUSY`/`ENXIO` 时回退 `default`，
   不要把失败当成“设备不存在”。（v0.7.5 的行为就是对的。）
3. **AppImage 不要打包 `libpipewire-0.3.so.0` / `libwayland-client.so.0`** 这类与系统守护进程
   ABI 强绑定的客户端库，更不要放进 `LD_LIBRARY_PATH`。
4. **Wayland 会话下剪贴板工具优先 `wl-copy`/`wl-paste`**，`xclip` 作为回退；不要因为
   `GDK_BACKEND=x11` 就认定用户没有 wl-clipboard。
5. **错误文案区分原因**：`EBUSY` 与 `ENXIO` 应给出不同提示，并打印 alsa-lib 的 `snd_strerror()`。
6. 工具链探测结果不要永久缓存（或在 `PATH` 变化后重新探测）。

## 临时绕过（用户侧，已实测可用）

详见同仓库 `README.md`：改 `audio_device=default` + 启动器 `LD_PRELOAD` 系统 libpipewire + 安装 xclip。

```bash
python3 - <<'EOF'
import json,os
p=os.path.expanduser('~/.config/shandianshuo/config.json')
d=json.load(open(p)); d['audio_device']='default'
json.dump(d,open(p,'w'),ensure_ascii=False,indent=2); os.chmod(p,0o600)
EOF
sudo pacman -S --needed xclip
# 启动器见 shandianshuo-launcher.sh
```
