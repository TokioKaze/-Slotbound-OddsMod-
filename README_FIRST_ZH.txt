Slotbound Odds Mod v1.3.1 — 单文件安装器测试版
作者：TokioKaze

适用：Steam 版 Slotbound v1.0.0(9)，Windows x64。
玩家无需安装 Python，无需联网安装依赖，无需 _internal 文件夹。

安装
1. 完整解压下载的安装包。
2. 关闭游戏，双击 SlotboundOddsModSetup.exe，首次启动请稍等。
3. 安装器会尝试找到 Steam 游戏目录；找不到时点击“浏览”，选择含 Slotbound.exe 的文件夹。
4. 点击“安装 / 更新”，程序会校验并备份原版 Slotbound.dat.orig。
5. 安装完成后从 Steam 启动游戏，无需再次运行安装器。
6. 游戏内 F8 打开概率面板，F7 打开功能面板。

恢复：关闭游戏，在安装器点击“恢复原版”；也可通过 Steam 验证游戏文件完整性。
更新：游戏更新后需重新确认 MOD 兼容性，不要把旧备份手动覆盖到新版本。

排错
启动失败时请记录提示，并通过 GitHub Issues 提交 Windows 版本和日志。
日志：%LOCALAPPDATA%\SlotboundOddsMod\installer.log
备用：%TEMP%\SlotboundOddsMod\installer.log
原生加载阶段的错误可能发生在日志创建前。
仓库：https://github.com/TokioKaze/-Slotbound-OddsMod-

验证范围
已完成本机成品自检和图形界面启动测试，用户已在另一台带编程环境的新电脑运行成功。
无编程环境的旧电脑兼容性尚未确认。本测试版不承诺支持所有旧系统或 32 位 Windows。
安装器及游戏内 MOD 面板目前使用中文；英文说明不代表界面已英文化。

开发者：源码仓库含 Build.bat 和 Python 源文件；普通玩家请从 Releases 下载安装包。
源码日期差异表示各文件最后修改时间不同，并不意味着需要把多个版本混用。
