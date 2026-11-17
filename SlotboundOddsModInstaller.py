#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Slotbound 概率 Mod 图形安装器          作者：TokioKaze

三个按钮：安装/更新、恢复原版、检查安装状态。实际逻辑全部在 slotbound_odds_patcher.py。
用 PyInstaller 打包后玩家不需要安装 Python（见 Build.bat / .github/workflows/release.yml）。

  SlotboundOddsModInstaller.exe              打开图形界面
  SlotboundOddsModInstaller.exe --selftest   不开界面，自检打包是否完整（退出码 0 = 正常）
"""
import os, re, sys, threading, queue, traceback

P = None  # Imported after startup logging is ready.

APP_TITLE = "Slotbound 概率 Mod 安装器 · by TokioKaze"
GAME_FOLDER = "Slotbound"


def app_dir():
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def is_game_dir(d):
    return bool(d) and os.path.isfile(os.path.join(d, "Slotbound.exe"))


def steam_libraries():
    """从注册表和 libraryfolders.vdf 找出所有 Steam 库目录（找不到就返回空列表）。"""
    roots = []
    try:
        import winreg
        for hive, key, val in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
                               (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
                               (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath")):
            try:
                with winreg.OpenKey(hive, key) as k:
                    roots.append(os.path.normpath(winreg.QueryValueEx(k, val)[0]))
            except OSError:
                pass
    except ImportError:
        pass
    libs = []
    for r in roots:
        libs.append(r)
        vdf = os.path.join(r, "steamapps", "libraryfolders.vdf")
        try:
            txt = open(vdf, encoding="utf-8", errors="replace").read()
            for m in re.finditer(r'"path"\s+"([^"]+)"', txt):
                libs.append(os.path.normpath(m.group(1).replace("\\\\", "\\")))
        except OSError:
            pass
    seen, out = set(), []
    for l in libs:
        if l.lower() not in seen:
            seen.add(l.lower()); out.append(l)
    return out


def find_game_dir():
    here = app_dir()
    for d in (here, os.path.dirname(here), os.getcwd()):
        if is_game_dir(d):
            return d
    for lib in steam_libraries():
        d = os.path.join(lib, "steamapps", "common", GAME_FOLDER)
        if is_game_dir(d):
            return d
    return ""


def selftest():
    """打包完整性自检：资源能找到、加密库可用、加载器能生成。"""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    mod = open(P.resource_path("SlotboundOddsMod.lua"), "rb").read()
    assert P.MARKER in mod
    P.resource_path("SlotboundOddsMod.ini")
    k = bytes(32); n = bytes(12)
    assert AESGCM(k).decrypt(n, AESGCM(k).encrypt(n, b"ok", b"a"), b"a") == b"ok"
    assert P.MARKER in P.build_stub(mod, b"\x1bLJ")
    import tkinter as tk
    from tkinter import scrolledtext
    test_root = tk.Tk()
    test_root.withdraw()
    scrolledtext.ScrolledText(test_root).pack()
    test_root.update()
    test_root.destroy()
    return 0


def run_gui():
    import tkinter as tk
    from tkinter import filedialog, messagebox, scrolledtext

    root = tk.Tk()
    root.title(APP_TITLE)
    root.minsize(640, 460)
    q = queue.Queue()
    busy = {"v": False}

    top = tk.Frame(root, padx=12, pady=10); top.pack(fill="x")
    tk.Label(top, text="游戏目录（里面有 Slotbound.exe）：", anchor="w").pack(fill="x")
    row = tk.Frame(top); row.pack(fill="x", pady=(4, 0))
    path = tk.StringVar(value=find_game_dir())
    tk.Entry(row, textvariable=path).pack(side="left", fill="x", expand=True)

    def browse():
        d = filedialog.askdirectory(title="选择 Slotbound 游戏目录", initialdir=path.get() or None)
        if d:
            path.set(os.path.normpath(d))
    tk.Button(row, text="浏览…", command=browse, width=8).pack(side="left", padx=(6, 0))
    tk.Label(top, fg="#666", anchor="w", justify="left",
             text="找不到？Steam 库里右键 Slotbound → 管理 → 浏览本地文件。安装前请先关闭游戏。").pack(fill="x", pady=(4, 0))

    btns = tk.Frame(root, padx=12); btns.pack(fill="x")
    box = scrolledtext.ScrolledText(root, height=14, state="disabled", wrap="word")
    box.pack(fill="both", expand=True, padx=12, pady=10)

    def log(msg):
        q.put(str(msg))

    def pump():
        try:
            while True:
                m = q.get_nowait()
                if callable(m):
                    m()
                    continue
                box.configure(state="normal"); box.insert("end", m + "\n"); box.see("end"); box.configure(state="disabled")
        except queue.Empty:
            pass
        root.after(80, pump)

    buttons = []

    def start(name, fn, confirm=None):
        if busy["v"]:
            return
        d = path.get().strip().strip('"')
        if not is_game_dir(d):
            messagebox.showerror(APP_TITLE, "这个文件夹里没有 Slotbound.exe，请先选择正确的游戏目录。")
            return
        if confirm and not messagebox.askokcancel(APP_TITLE, confirm):
            return
        busy["v"] = True
        for b in buttons:
            b.configure(state="disabled")
        log("—— " + name + " ——")

        def work():
            ok, err = True, None
            try:
                fn(d, log=log)
            except P.PatchError as e:
                ok, err = False, str(e)
            except Exception as e:  # 未预料的错误：给出完整信息方便反馈
                ok, err = False, "程序出错：%s: %s\n\n%s" % (type(e).__name__, e, traceback.format_exc())
            def done():
                busy["v"] = False
                for b in buttons:
                    b.configure(state="normal")
                if not ok:
                    log("[失败] " + err)
                    messagebox.showerror(APP_TITLE, name + "失败：\n\n" + err[:1200])
                elif name != "检查安装状态":
                    messagebox.showinfo(APP_TITLE, name + "完成。")
            q.put(done)
        threading.Thread(target=work, daemon=True).start()

    for text, name, fn, confirm in (
        ("安装 / 更新", "安装", lambda d, log: P.install(d, log=log), None),
        ("恢复原版", "恢复原版", P.restore, "确定把游戏恢复为原版吗？（你的配置文件会保留）"),
        ("检查安装状态", "检查安装状态", P.status, None),
    ):
        b = tk.Button(btns, text=text, width=16, height=2, command=lambda n=name, f=fn, c=confirm: start(n, f, c))
        b.pack(side="left", padx=(0, 8))
        buttons.append(b)

    log("选择游戏目录后点击“安装 / 更新”。安装会先校验并备份原版（Slotbound.dat.orig）。")
    log("安装完成后直接从 Steam 启动游戏即可，无需再运行本工具。游戏内 F8 = 概率面板，F7 = 功能面板。")
    if not path.get():
        log("没有自动找到游戏目录，请点“浏览…”手动选择。")
    def close():
        if busy["v"]:
            messagebox.showinfo(APP_TITLE, "正在安装或恢复，请等待操作完成后关闭。")
            return
        root.destroy()
    root.protocol("WM_DELETE_WINDOW", close)
    if "--gui-smoke" in sys.argv:
        root.after(800, root.destroy)
    pump()
    root.mainloop()


def main():
    global P
    import tempfile, platform, datetime
    log_dir = os.path.join(os.environ.get("LOCALAPPDATA") or tempfile.gettempdir(), "SlotboundOddsMod")
    try:
        os.makedirs(log_dir, exist_ok=True)
    except OSError:
        log_dir = os.path.join(tempfile.gettempdir(), "SlotboundOddsMod")
        os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, "installer.log")
    diagnostic = "--selftest" in sys.argv
    with open(log_path, "a", encoding="utf-8") as stream:
        stream.write("\n=== %s | %s | %s ===\n" % (datetime.datetime.now(), platform.platform(), sys.version))
        stream.flush()
        try:
            import slotbound_odds_patcher as P
            if diagnostic:
                selftest()
                stream.write("SELFTEST PASSED\n")
            else:
                run_gui()
            return 0
        except BaseException:
            error = traceback.format_exc()
            stream.write(error)
            stream.flush()
            if not diagnostic:
                import ctypes
                ctypes.windll.user32.MessageBoxW(None, "安装器启动失败。错误日志：\n" + log_path + "\n\n" + error[-1400:], APP_TITLE, 0x10)
            return 1


if __name__ == "__main__":
    sys.exit(main())
