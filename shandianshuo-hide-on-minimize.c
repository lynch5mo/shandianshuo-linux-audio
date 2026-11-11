/*
 * shandianshuo-hide-on-minimize.so
 *
 * 让「闪电说」的关闭/最小化按钮在 Hyprland（以及 Sway/Niri 等没有最小化语义的
 * 合成器）上真正生效：把 gtk_window_iconify() 换成 gtk_widget_hide()。
 *
 * 背景
 *   闪电说的关闭按钮走 Tauri 的 window.minimize() → GTK 的 gtk_window_iconify()。
 *   GTK 在 X11 上把最小化翻译成 ICCCM 的 WM_CHANGE_STATE(IconicState)，
 *   Hyprland 只对原生 Wayland 客户端实现最小化（xdg_toplevel.set_minimized），
 *   对 Xwayland 窗口的 iconify 请求直接忽略 —— 于是窗口纹丝不动，
 *   应用又以为“已经最小化到托盘了”，用户在 Hyprland 上根本关不掉这个窗口。
 *
 *   而闪电说必须用 GDK_BACKEND=x11 跑在 Xwayland 上（录音浮窗定位依赖它），
 *   所以没法靠切到 Wayland 后端绕过。
 *
 * 做法
 *   用 LD_PRELOAD 覆盖 gtk_window_iconify：窗口直接 hide（应用继续在后台常驻，
 *   全局快捷键照旧工作，托盘「显示闪电说」走 deiconify + present 会重新显示）。
 *   只覆盖 iconify，deiconify / present 仍走真正的 GTK 实现。
 *
 * 编译
 *   gcc -O2 -fPIC -shared -o libshandianshuo-hide-on-minimize.so \
 *       shandianshuo-hide-on-minimize.c
 *   （不需要 GTK 头文件：只用不透明指针 + 外部符号声明）
 *
 * 卸载
 *   从启动脚本的 LD_PRELOAD 里删掉这个 .so 即可。
 */

typedef struct _GtkWidget GtkWidget;
typedef struct _GtkWindow GtkWindow;

extern void gtk_widget_hide(GtkWidget *widget);

/* 覆盖 GTK 的最小化：改成隐藏窗口（窗口从屏幕消失，进程继续常驻） */
void gtk_window_iconify(GtkWindow *window)
{
    if (window)
        gtk_widget_hide((GtkWidget *)window);
}
