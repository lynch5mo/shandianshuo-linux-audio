# 闪电说 (Shandianshuo) v0.7.7 Linux 录音失败 —— 复现步骤与解决方案

适用于：AppImage 版闪电说在 **PipeWire** 桌面（Arch/Omarchy、Fedora、Ubuntu 22.04+ 等都一样）上，
按快捷键录音时提示「检查麦克风」「未检测到音频输入设备」，或转写成功但无法上屏。

三个问题可以独立出现，也可以像我这样叠在一起。每个问题都有：现象 → 复现 → 根因 → 修法。

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 「检查麦克风」/ device-error 通知 | v0.7.7 自动选设备时会直接打开 ALSA 硬件节点 `front:CARD=...,DEV=0`，而该 PCM 已被 PipeWire 独占 → `EBUSY` | `config.json` 里 `"audio_device": "default"` |
| 2 | 「未检测到音频输入设备」 | AppImage 内打包了旧版 `libpipewire-0.3.so.0`，遮蔽系统库 → `libasound_module_pcm_pipewire.so` 加载失败 → `snd_pcm_open("default")` 返回 `ENXIO` | 启动器里 `LD_PRELOAD` 系统 libpipewire |
| 3 | 转写成功但「操作未完成：自动粘贴失败」 | 目标被判为 X11 → 只用 `xclip`，系统未安装；不会回退到已存在的 `wl-copy` | `sudo pacman -S xclip`，然后重启应用 |

---

## 环境（复现基线）

```
OS        Omarchy (Arch base) / Hyprland (Wayland + Xwayland)
Kernel    7.2.15-1-omarchy
pipewire  1:1.6.9-1         pipewire-alsa 1:1.6.9-1
wireplumber 0.5.18-1
alsa-lib  1.2.16.1-1        alsa-utils 1.2.16-1
硬件      MacBook8,1 (Early 2015 12")，声卡 HDA Intel PCH / CS4208
应用      闪电说 v0.7.7 (AppImage)，由 v0.7.5 自动升级而来
```

> 与硬件无关：只要是 PipeWire 会话 + 内置/任意 ALSA 声卡，问题 1 和问题 2 都能复现。

---

## 问题 1：自动选设备 → 直开 ALSA 硬件节点 → EBUSY

### 现象

```
[Audio] Resolved device: "HDA Intel PCH, CS4208 Analog" (raw: "front:CARD=PCH,DEV=0", mode: auto)
ERROR [Audio] Thread error: The requested device is no longer available. For example, it has been unplugged.
WARN  [Recording] AudioThread unresponsive, recreating
ERROR [RecordingGateway] Failed to start recording: AudioThread unresponsive
INFO  [Notification] Showing notification: device-error
```

界面提示「检查麦克风」。反复按键只会重复上面五步。

### 复现 / 验证

```bash
# 1. 确认 PipeWire 持有采集设备
pactl list sources short | grep capture

# 2. 任何进程直接开硬件节点都会失败（PipeWire 已占用）
arecord -D front:CARD=PCH,DEV=0 -f S16_LE -r 48000 -c 2 -d 2 /tmp/x.wav
#   arecord: audio open error: 设备或资源忙   (EBUSY)

# 3. 走 PipeWire 的 default 则正常
arecord -D default -f S16_LE -r 48000 -c 2 -d 2 /tmp/y.wav   # OK

# 4. 让 PipeWire 释放设备后，硬件节点又能直接打开（证明不是权限/硬件问题）
pactl suspend-source <source-id> 1
arecord -D hw:1,0 ... /tmp/z.wav                             # OK
```

### 根因

v0.7.5 自动选择时选的是 `default`：

```
[v0.7.5] INFO [DeviceCache] Pre-warmed: selected 'default'
```

v0.7.7 之后改为把 PipeWire 音源映射成 ALSA 硬件节点（日志里可见
`plughw:CARD=,DEV=`、`node.name`、`@DEFAULT_AUDIO_SOURCE@`、`wpctl get-default-source` 等探测），
最终返回 `front:CARD=<CARD>,DEV=0`。在 PipeWire 会话里，采集 PCM 由 PipeWire 独占，
其它进程直接 `snd_pcm_open("hw:/plughw:/front:...")` 一律 `EBUSY`，cpal 把它折算成
`DeviceNotAvailable`。

### 修法（用户侧）

```bash
# 退出应用后修改
python3 - <<'EOF'
import json,os
p=os.path.expanduser('~/.config/shandianshuo/config.json')
d=json.load(open(p)); d['audio_device']='default'
json.dump(d,open(p,'w'),ensure_ascii=False,indent=2); os.chmod(p,0o600)
EOF
```

重启应用后日志应出现 `mic=default` 与 `audio=fixed`：

```
[ConfigSummary] version=3 ... audio=fixed
[App] 闪电说 v0.7.7 | linux x86_64 | ... | mic=default
```

> 之后不要在设置界面把麦克风改回「系统默认」，否则会再次落到硬件节点。

---

## 问题 2：AppImage 打包的旧 libpipewire → `snd_pcm_open` ENXIO

### 现象（改了问题 1 之后才会遇到）

```
[Audio] Resolved device: "Default ALSA Output (currently PipeWire Media Server)" (raw: "default", mode: fixed)
ERROR [Audio] Thread error: A backend-specific error has occurred:
      ALSA function 'snd_pcm_open' failed with error 'No such device or address (6)'
```

界面提示「未检测到音频输入设备」。注意 `default` 在系统里是能用的，所以这个错误很有迷惑性。

### 复现

AppImage 运行时会把自带的 `usr/lib` 塞进 `LD_LIBRARY_PATH`，其中有一份旧的
`libpipewire-0.3.so.0`（本例 922 KB，2025-08-05；系统版为 1.6.9）。

```bash
# 解包观察
./shandianshuo.AppImage --appimage-extract
ls -l squashfs-root/usr/lib/libpipewire-0.3.so.0*

# 复现 alsa 插件加载失败：把 AppImage 的库目录加进 LD_LIBRARY_PATH
gcc -o /tmp/t -x c - -lasound <<'EOF'
#include <alsa/asoundlib.h>
#include <stdio.h>
int main(void){snd_pcm_t*p;int e=snd_pcm_open(&p,"default",SND_PCM_STREAM_CAPTURE,0);
printf("%s\n",e?snd_strerror(e):"OK");return 0;}
EOF
/tmp/t                                                        # OK
LD_LIBRARY_PATH=squashfs-root/usr/lib /tmp/t                  # No such device or address
```

stderr 里能看到真正的原因：

```
ALSA lib dlmisc.c:339:(snd_dlobj_cache_get0) [error.core] Cannot open shared library
libasound_module_pcm_pipewire.so
(.../libasound_module_pcm_pipewire.so: undefined symbol: pw_log_topic_register)
```

### 根因

系统的 pipewire-alsa 插件 `libasound_module_pcm_pipewire.so` 依赖新版 libpipewire 符号
（`pw_log_topic_register`），但 AppImage 的 `LD_LIBRARY_PATH` 让 dlopen 命中了旧库，
插件加载失败。alsa-lib 把“插件加载失败”折算成 `-ENXIO`，应用侧就表现为“设备不存在”。

### 修法（用户侧）

用系统库预加载，遮蔽 AppImage 自带的那份（与 v0.7.5 时代修 `libwayland-client` 的手法相同）：

```bash
cat > ~/.local/bin/shandianshuo <<'SH'
#!/usr/bin/env bash
# 用系统库遮蔽 AppImage 自带的旧库：
#  - libpipewire-0.3.so.0：否则 pipewire-alsa 插件加载失败，snd_pcm_open 报 ENXIO
#  - libwayland-client.so.0：旧版会遮蔽系统 wayland，导致 WebKit 子进程启动即崩溃
exec env \
  LD_PRELOAD=/usr/lib/libpipewire-0.3.so.0:/usr/lib/libwayland-client.so.0 \
  "${SHANDIANSHUO_APPIMAGE:-$HOME/Applications/shandianshuo.AppImage}" "$@"
SH
chmod +x ~/.local/bin/shandianshuo
```

然后让启动入口都指向这个包装脚本。Arch + 自动启动（`.desktop` 由
systemd-xdg-autostart-generator 转成 `app-<name>@autostart.service`）时：

```bash
# 把 .desktop 的 Exec 改成包装脚本
sed -i 's|^Exec=.*|Exec='"$HOME"'/.local/bin/shandianshuo %U|' \
  ~/.local/share/applications/shandianshuo.desktop ~/.config/autostart/shandianshuo.desktop 2>/dev/null

systemctl --user restart app-shandianshuo@autostart.service
```

验证：进程里应出现系统库，且不再是 AppImage 挂载目录里的那份。

```bash
pid=$(pgrep -f 'shandianshuo --autostart' | head -1)
grep -oE '/[^ ]*libpipewire[^ ]*' /proc/$pid/maps | sort -u
#   /usr/lib/libpipewire-0.3.so.0.1609.0
```

---

## 问题 3：转写成功但无法上屏（缺 xclip）

### 现象

```
[ASR] Completed: *** (35 chars)
[linux] Detected display server: Wayland
[linux] Tool chain: type=Some(Wtype), clip=None (X11), paste=Some(Wtype)
ERROR [Inject] voice input paste failed: No clipboard tool available.
      Install wl-copy/wl-paste (Wayland) or xclip (X11).
```

界面提示「操作未完成：自动粘贴和剪贴板写入均失败，请检查 Linux 输入权限及剪贴板工具」。
录音和识别都成功了，转写记录保存在应用内。

### 根因

App 以 `GDK_BACKEND=x11` 运行在 Xwayland 上（录音浮窗定位依赖它），于是粘贴目标被判为 X11，
工具链只找 `xclip`；系统里虽然装了 `wl-clipboard`（`wl-copy`/`wl-paste`），但不会回退过去。

顺带记录的坑：本机 Hyprland 下 **X11 与 Wayland 剪贴板并未互相同步**
（`xclip -i` 后 `wl-paste` 读不到；`wl-copy` 后 `xclip -o` 报 `target STRING not available`），
所以工具链选择是按目标窗口类型来的，跨类型粘贴会粘到旧内容。

### 修法

```bash
sudo pacman -S --needed xclip        # Debian/Ubuntu: sudo apt install xclip
```

**装完要重启应用**：工具链在第一次粘贴时探测并缓存（`[linux] Tool chain:` 只打印一次）。

---

## 完整验证

```bash
# 1. 设备配置
python3 -c "import json;print(json.load(open('$HOME/.config/shandianshuo/config.json'))['audio_device'])"
#   default

# 2. 进程使用系统 libpipewire
pid=$(pgrep -f 'shandianshuo --autostart' | head -1)
grep -oE '/[^ ]*libpipewire[^ ]*' /proc/$pid/maps | sort -u

# 3. 按快捷键说一句话，日志里应出现：
#    [Audio] Recording with: ... 44100Hz, 2 channels
#    [CloudASR-Streaming] Transcription completed ... N chars
#    [Transcription] Finalized voice input record ... as success
#    （且没有 Thread error / paste failed）
tail -40 ~/.config/shandianshuo/logs/shandianshuo.$(date +%F).log | grep -vE "Overlay|Timing"
```

---

## 给上游的修复建议

1. **不要直接打开 ALSA 硬件节点**。PipeWire/PulseAudio 会话里 `hw:`/`plughw:`/`front:` 都被服务器独占，
   必然 `EBUSY`。优先用 PipeWire/PulseAudio API，或 ALSA 的 `default` / `pipewire` / `pulse` 设备。
2. **自动选设备要做可用性探测**：逐个尝试 `snd_pcm_open`，`EBUSY`/`ENXIO` 时回退到 `default`，
   而不是把失败当成“设备不存在”。v0.7.5 选 `default` 的行为是正确的，v0.7.7 是回归。
3. **AppImage 不要打包 `libpipewire-0.3.so.0` 这类系统服务客户端库**（同理 `libwayland-client`）。
   它们是 ABI 与系统守护进程强绑定的，塞进 `LD_LIBRARY_PATH` 会让系统的 alsa/gtk 插件加载失败。
4. **剪贴板工具检测要在 Wayland 下优先 `wl-copy`/`wl-paste`**，`xclip` 只作为回退；
   不要根据 `GDK_BACKEND=x11` 就认定用户没有 wl-clipboard。
5. **报错文案区分原因**：`EBUSY`（设备被占用）与 `ENXIO`（插件/设备不可用）应给出不同提示，
   并在日志里打印 alsa-lib 的 `snd_strerror()`，否则用户只能看到「检查麦克风」。
6. 工具链探测结果建议不要永久缓存，或在 `PATH` 变化后重新探测（用户装完 `xclip` 必须重启应用这点很反直觉）。

---

## 附：一句版排障流程

```
按快捷键报「检查麦克风」
  → pactl list sources short        # 设备存在吗
  → arecord -D default ...          # PipeWire 路径能录吗
      ├─ 能：改 config.json audio_device=default
      └─ 不能：检查 libpipewire 遮蔽（本文件问题 2）
转写成功但不上屏
  → 装 xclip，重启应用
```
