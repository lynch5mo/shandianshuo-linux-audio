# 闪电说 (Shandianshuo) v0.7.7 Linux 录音失败 —— 复现步骤与解决方案

适用于：AppImage 版闪电说在 **PipeWire** 桌面（Arch/Omarchy、Fedora、Ubuntu 22.04+ 等都一样）上，
按快捷键录音时提示「检查麦克风」「未检测到音频输入设备」，或转写成功但无法上屏。

问题可以独立出现，也可以像我这样叠在一起。每个问题都有：现象 → 复现 → 根因 → 修法。
前三个是「录音/上屏」链路，后两个是窗口与进程生命周期。

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 「检查麦克风」/ device-error 通知 | v0.7.7 自动选设备时会直接打开 ALSA 硬件节点 `front:CARD=...,DEV=0`，而该 PCM 已被 PipeWire 独占 → `EBUSY` | `config.json` 里 `"audio_device": "default"` |
| 2 | 「未检测到音频输入设备」 | AppImage 内打包了旧版 `libpipewire-0.3.so.0`，遮蔽系统库 → `libasound_module_pcm_pipewire.so` 加载失败 → `snd_pcm_open("default")` 返回 `ENXIO` | 启动器里 `LD_PRELOAD` 系统 libpipewire |
| 3 | 转写成功但「操作未完成：自动粘贴失败」 | 目标被判为 X11 → 只用 `xclip`，系统未安装；不会回退到已存在的 `wl-copy` | `sudo pacman -S xclip`，然后重启应用 |
| 4 | 点「关闭」窗口关不掉，纹丝不动 | 关闭走 `window.minimize()`（最小化到托盘），Hyprland/Sway 对 Xwayland 窗口的最小化请求不生效 → 无反应 | 用 LD_PRELOAD 垫片把 `gtk_window_iconify` 换成 `gtk_widget_hide`，关闭即隐藏、后台常驻 |
| 5 | 退出后仍显示「运行中」，无法重新启动/判断状态 | 粘贴时 fork 的 `xclip -selection clipboard` 常驻服务剪贴板，而自动启动单元是 `ExitType=cgroup` → 单元永远停在 active | 清掉残留 `xclip`；用仓库里的 `shandianshuo-quit.sh` |

---

## 文件说明

| 文件 | 用途 |
|---|---|
| `ISSUE.md` | 上游 issue 正文（录音链路，含最小复现、根因、修复建议） |
| `FEEDBACK.md` | 一屏版反馈稿，用于应用内「常见问题/反馈」 |
| `shandianshuo-launcher.sh` | 可直接安装的启动器 |
| `shandianshuo-quit.sh` | 彻底退出（含清理残留 `xclip`） |
| `shandianshuo-hide-on-minimize.c` | 让「关闭」真正隐藏窗口（minimize → hide）的 LD_PRELOAD 垫片 |
| `ISSUE-2-window.md` | 问题 4/5 的上游 issue 正文 |

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

## 问题 4：关闭按钮无效（minimize 在 Hyprland 上是空操作）

### 现象

点标题栏右上的「关闭」，窗口纹丝不动，既不关也不隐藏。点两次就是下面两行日志：

```
INFO Main window minimized on Linux tray fallback
INFO Main window minimized on Linux tray fallback
```

### 证据

窗口仍然是 mapped（在屏幕上）：

```bash
hyprctl clients -j | python3 -c "import json,sys;[print({k:c.get(k) for k in ('title','mapped','hidden','workspace')}) for c in json.load(sys.stdin) if c.get('class')=='Shandianshuo']"
# {'title': '闪电说', 'mapped': True, 'hidden': False, 'workspace': {'id': 1, 'name': '1'}}
```

### 根因

关闭请求的实现是「最小化到托盘」（日志里明确写了 `Linux tray fallback`），而不是
隐藏窗口（`set_visible(false)`）或退出。

- Hyprland 只对**原生 Wayland** 客户端实现了最小化（`CXWaylandSurface::setMinimized`，即
  `xdg_toplevel.set_minimized`）；
- 对 **Xwayland** 窗口的 X11 `IconicState` 请求不做处理；
- 而闪电说因为录音浮窗定位需要 `GDK_BACKEND=x11`，必然跑在 Xwayland 上。

于是“最小化”在本机等于空操作：窗口不隐藏，也无法关闭。应用自己的「最小化」按钮同理无效。
（GNOME/KDE 上同样动作是有效的，所以这个 bug 只在 Hyprland/Sway/Niri 这类无最小化语义的合成器上暴露。）

### 修法（用户侧）：把 minimize 换成 hide

它的本意就是“关闭 = 收进托盘、后台常驻”（全局快捷键还要用），所以不要退出应用，
而是让「关闭」真正**隐藏窗口**。做法：用 `LD_PRELOAD` 覆盖 `gtk_window_iconify()`，
改为 `gtk_widget_hide()`。

源码 `shandianshuo-hide-on-minimize.c`，编译安装：

```bash
mkdir -p ~/.local/lib/shandianshuo
gcc -O2 -fPIC -shared -o ~/.local/lib/shandianshuo/libshandianshuo-hide-on-minimize.so \
    shandianshuo-hide-on-minimize.c
```

再接进启动器（追加到已有的 `LD_PRELOAD` 列表，见 `shandianshuo-launcher.sh`）：

```bash
LD_PRELOAD=/usr/lib/libpipewire-0.3.so.0:/usr/lib/libwayland-client.so.0:$HOME/.local/lib/shandianshuo/libshandianshuo-hide-on-minimize.so
```

垫片本身可以脱离应用单独验证（写个 200ms 后调 `gtk_window_iconify` 的 GTK 小程序）：

```
无 shim：after iconify → visible=1   （真 iconify，窗口不会隐藏）
有 shim：after iconify → visible=0   （变成 hide）
```

实测效果（点击「关闭」后）：

```bash
hyprctl clients -j | grep -c Shandianshuo   # 0：窗口从合成器里消失（不是最小化）
pgrep -f 'shandianshuo --autostart'         # 仍在：后台常驻
busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
  org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems | grep -c ayatana   # 1：托盘仍在
```

隐藏后录音链路完全正常：

```
INFO [Audio] Recording with: Default ALSA Output (currently PipeWire Media Server), 44100Hz, 2 channels
INFO [Inject] Success: *** (54 chars)
INFO [Transcription] Finalized voice input record … as success
```

### 窗口隐藏后怎么叫回来

1. **再点一次启动器图标/命令** —— 走单实例激活：

```
INFO [Single Instance] Another instance attempted to start
INFO [Window] single-instance activation called gtk deiconify() and present_with_time()
```

2. 托盘图标（顶部栏右侧托盘区）→「显示闪电说」。菜单项 DBus 层面是 `显示闪电说` / `退出`：

```bash
M=/org/ayatana/NotificationItem/tray_icon_tray_app_main/Menu
busctl --user call :1.220 $M com.canonical.dbusmenu GetLayout iias 0 -- -1 0
# id 2 = 显示闪电说，id 3 = 退出
```

### 真想退出时

1. 托盘 →「退出」；
2. 或 `shandianshuo-quit`（已验证，会连带清掉问题 5 里那个残留 `xclip`）。

```bash
install -Dm755 shandianshuo-quit.sh ~/.local/bin/shandianshuo-quit
shandianshuo-quit
```

---

## 问题 5：退出后「还在运行」——残留 xclip 让自动启动单元卡在 active

### 现象

托盘「退出」后应用确实消失了，但 `systemctl --user is-active` 仍然是 `active`，于是看起来
“应用还在运行”，而 unit 状态与实际不符。

```bash
systemctl --user is-active app-shandianshuo@autostart.service    # active（其实已经没有主进程）
systemctl --user status app-shandianshuo@autostart.service        # Process: … (code=exited, status=0/SUCCESS)
```

### 复现 / 根因

```bash
cg=$(systemctl --user show -p ControlGroup --value app-shandianshuo@autostart.service)
for p in $(cat /sys/fs/cgroup$cg/cgroup.procs); do ps -o pid,cmd -p $p --no-headers; done
# 136102 xclip -selection clipboard -target UTF8_STRING
```

- 上屏前它会用 `xclip -selection clipboard ...` 写剪贴板；`xclip` 写完会 fork 常驻以提供 selection
  （这是 xclip 的正常行为，不是 bug）；
- 这个 fork 出来的 `xclip` 落在应用的 cgroup 里；
- `~/.config/autostart/*.desktop` 被 systemd-xdg-autostart-generator 转成
  `app-…@autostart.service`，带 `ExitType=cgroup`：只要 cgroup 里还有**任何**进程，单元就保持 active。

### 修法

用 `shandianshuo-quit.sh`：先记录 cgroup 内的 pid，`systemctl --user stop` 之后再兜底 kill 残留。
或者手动：

```bash
systemctl --user stop app-shandianshuo@autostart.service
pgrep -f 'xclip -selection clipboard' | xargs -r kill
```

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
7. **关闭策略不要用 minimize**：Linux（尤其 Hyprland/Sway/Niri）没有最小化语义。应当
   - 有托盘 → `window.hide()` / `set_visible(false)`；
   - 无托盘 → 直接退出；
   - 若仍调 `minimize()`，请至少回读 `is_minimized()`，失败则退回 `hide()`，不要假设“已最小化”。
8. **外部命令不要留在进程树里**：`xclip` 用 `-l 1`（或 `-loops 1`）并在写完后等它退出，
   或改用应用内剪贴板实现。否则配合 systemd 的 `ExitType=cgroup`，会让自动启动单元永远停在
   `active`，也让用户无法通过 `systemctl` 判断应用是否真的在跑。

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
点「关闭」没反应
  → 正常现象（close=最小化，Hyprland 无最小化）→ 托盘「退出」或 shandianshuo-quit
退出后 systemctl 仍显示 active
  → 残留 xclip 占着 cgroup → shandianshuo-quit
```
