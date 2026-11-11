# [Linux] 关闭按钮无效（close → minimize，Hyprland 上无效果）；退出后自动启动单元卡在 active

> 第 1 个问题是窗口关闭策略在无最小化语义的合成器上失效；
> 第 2 个问题是 fork 出来的 `xclip` 常驻，配合 systemd 的 `ExitType=cgroup` 让单元永远 active。
> 二者都在 Linux + Hyprland（Wayland + Xwayland）上复现。

## 环境

| 项 | 值 |
|---|---|
| 发行版 | Omarchy（Arch 系），Hyprland 0.56.2 |
| 会话 | Wayland + Xwayland；应用以 `GDK_BACKEND=x11` 运行（浮窗定位需要） |
| pipewire | 1:1.6.9-1 |
| 应用 | 闪电说 v0.7.7 AppImage |
| 托盘宿主 | quickshell（`org.kde.StatusNotifierWatcher` + `StatusNotifierHost`），托盘项为 Ayatana/AppIndicator |

## 问题 1：点「关闭」窗口关不掉

### 复现步骤

1. 打开闪电说主窗口（此时 `hyprctl clients` 里 `class=Shandianshuo`，`xwayland=true`）。
2. 点击标题栏右上角的「关闭」，连点两次。
3. 实际：窗口没有任何变化，既不关闭也不隐藏。
4. 日志 `~/.config/shandianshuo/logs/shandianshuo.<date>.log`：

```
INFO Main window minimized on Linux tray fallback
INFO Main window minimized on Linux tray fallback
```

5. 窗口状态验证 —— 依旧是 mapped：

```bash
hyprctl clients -j | python3 -c "import json,sys;[print({k:c.get(k) for k in ('title','mapped','hidden','workspace')}) for c in json.load(sys.stdin) if c.get('class')=='Shandianshuo']"
# {'title': '闪电说', 'mapped': True, 'hidden': False, 'workspace': {'id': 1, 'name': '1'}}
```

### 根因

关闭请求被实现成“最小化到托盘”，而不是隐藏窗口或退出：

- Hyprland 只对原生 Wayland 客户端实现最小化（`CXWaylandSurface::setMinimized` → `xdg_toplevel.set_minimized`）；
- 对 Xwayland 窗口的 X11 `IconicState`（iconify）请求不做处理；
- 闪电说因为录音浮窗定位必须 `GDK_BACKEND=x11`，所以一定跑在 Xwayland 上。

结果：minimize 变成空操作；`is_minimized()` 之类的回读也没有起到“失败则隐藏”的兜底作用。
应用自身的「最小化」按钮同样无效。GNOME/KDE 上该动作有效，所以问题只在 Hyprland / Sway / Niri
这类没有最小化语义的合成器上暴露。

### 期望行为

- 有托盘时：`window.hide()`（`set_visible(false)`），或
- 无托盘时：直接退出；
- 若坚持 `minimize()`，请在调用后检查实际状态，失败时退回 `hide()`。

### 现有绕过

用户侧可以用一个 `LD_PRELOAD` 垫片把 `gtk_window_iconify()` 换成 `gtk_widget_hide()`，
这样关闭就是“隐藏窗口、后台常驻”（符合原意），实测有效：

```bash
gcc -O2 -fPIC -shared -o ~/.local/lib/shandianshuo/libshandianshuo-hide-on-minimize.so \
    shandianshuo-hide-on-minimize.c
# 然后把上面这个 .so 加进启动 AppImage 的 LD_PRELOAD
```

垫片验证（独立 GTK 小程序）：无 shim `visible=1`，有 shim `visible=0`。
应用到隐藏后的状态：`hyprctl clients` 中不再有该窗口、进程仍在、托盘项仍在、录音/上屏正常。
叫回窗口：再启动一次（单实例激活 → `deiconify + present_with_time`）或托盘「显示闪电说」。

需要真正退出时：托盘「退出」，或 `systemctl --user stop app-shandianshuo@autostart.service`
（还需处理下面第 2 个问题里的残留 `xclip`）。

---

## 问题 2：退出后 systemd 自动启动单元仍是 active（残留 xclip）

### 复现步骤

1. 通过托盘「退出」退出应用（主进程正常退出，`status=0/SUCCESS`）。
2. 检查单元状态：

```bash
systemctl --user is-active app-shandianshuo@autostart.service   # active
systemctl --user show -p ControlGroup --value app-shandianshuo@autostart.service
# /user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-shandianshuo@autostart.service
for p in $(cat /sys/fs/cgroup<上面的路径>/cgroup.procs); do ps -o pid,cmd -p $p --no-headers; done
# 136102 xclip -selection clipboard -target UTF8_STRING
```

3. 实际：主进程已经没了，但单元永远停在 `active (running)`。

### 根因

- 上屏前应用调用 `xclip -selection clipboard …` 写剪贴板；`xclip` 写完后会 fork 常驻以提供 selection
  （xclip 的正常行为）；
- 这个子进程落在应用自己的 cgroup 里；
- `~/.config/autostart/shandianshuo.desktop` 由 systemd-xdg-autostart-generator 生成
  `app-shandianshuo@autostart.service`，其 `ExitType=cgroup`：只要 cgroup 内还有任何进程，单元就保持 active。

### 期望行为

- 调用 `xclip` 时加 `-l 1`（`-loops 1`，写完即退出）并 `wait()`；或
- 用应用内剪贴板实现，不 fork 外部常驻进程；
- 退出流程里清理自己 fork 的子进程。

### 现有绕过

```bash
systemctl --user stop app-shandianshuo@autostart.service
pgrep -f 'xclip -selection clipboard' | xargs -r kill
```

或仓库里的 `shandianshuo-quit.sh`：先记录单元 cgroup 内的 pid，`systemctl stop` 后兜底 kill 残留。
