Slotbound Odds Mod v1.3.1 — Standalone Installer Preview
Author: TokioKaze

Target: Steam edition of Slotbound v1.0.0(9), Windows x64.
Players do not need Python, online dependency installation, or an _internal folder.

Installation
1. Extract the downloaded installer archive.
2. Close the game and run SlotboundOddsModSetup.exe. Allow a moment for the first launch.
3. The installer attempts to locate your Steam game folder. If necessary, click Browse (浏览) and select the folder containing Slotbound.exe.
4. Click Install / Update (安装 / 更新). The installer validates the files and backs up the original as Slotbound.dat.orig.
5. Launch the game through Steam. You do not need to run the installer again to play.
6. Press F8 for probability settings and F7 for the utilities panel.

Restore: Close the game and click Restore Original (恢复原版), or verify game files through Steam.
Updates: Check mod compatibility again after game updates. Do not manually replace updated files with an old backup.

Troubleshooting
Report the error message, Windows version, and installer log through GitHub Issues.
Log: %LOCALAPPDATA%\SlotboundOddsMod\installer.log
Fallback: %TEMP%\SlotboundOddsMod\installer.log
Native loader errors can occur before the log is created.
Repository: https://github.com/TokioKaze/-Slotbound-OddsMod-

Testing status
Packaged resource/crypto checks and GUI startup tests passed locally. The user also ran the package successfully on another newer computer with development tools installed.
Compatibility with older computers without development tools remains unconfirmed. This preview does not promise support for all older Windows versions or 32-bit Windows.
The installer and in-game mod interface are currently in Chinese; this English guide does not translate the interface.

Developers: The source repository includes Build.bat and Python files. Players should download the installer from Releases.
Different source modification dates reflect individual file edits, not a requirement to combine separate versions.
