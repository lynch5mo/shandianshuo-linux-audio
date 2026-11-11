#!/usr/bin/env bash
# 彻底退出「闪电说」
#
# 为什么需要它：闪电说的「关闭」按钮走的是 window.minimize()（最小化到托盘），
# 而 Hyprland 对 Xwayland 窗口的最小化请求没有效果 → 点了关闭窗口纹丝不动。
# 另有一处坑：粘贴时它 fork 出的 `xclip -selection clipboard ...` 会常驻服务剪贴板，
# 而自动启动单元用了 ExitType=cgroup —— 这个残留的 xclip 会让 systemd 一直认为
# 应用还在运行（`systemctl --user is-active` 仍是 active），于是无法判断是否已退出。
#
# 本脚本：停掉 systemd 用户单元，并清掉该单元 cgroup 里残留的子进程。
set -u

unit=app-shandianshuo@autostart.service
cg=$(systemctl --user show -p ControlGroup --value "$unit" 2>/dev/null)

# 先记录单元内的进程，stop 之后再清残留（AppImage runtime / xclip）
pids=""
if [ -n "${cg:-}" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ]; then
  pids=$(cat "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null)
fi

systemctl --user stop "$unit" 2>/dev/null

# 正常情况下 stop 已经 TERM 了整个 cgroup；这里兜住 ignore-SIGTERM 的残留
sleep 1
for p in $pids; do
  if [ -d "/proc/$p" ]; then
    kill "$p" 2>/dev/null
  fi
done

sleep 1
if systemctl --user is-active --quiet "$unit"; then
  echo "闪电说 仍在运行（单元仍是 active）"
  exit 1
fi
echo "闪电说 已退出"
