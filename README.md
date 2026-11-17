# Slotbound Odds Mod / Slotbound 概率 Mod（转运军团）

Author: **TokioKaze** · Mod version: **v1.3.1** · Supported game: **Slotbound v1.0.0(9)** (Steam edition)

A local single-player mod for Slotbound. Customize **rarity probabilities** for slots and Fate Stones, adjust **class symbol probabilities**, and use an in-game utilities panel for gold, essence, spins, unlimited nudges, guaranteed Joker chains, and more.

> This is an unofficial mod and is not affiliated with the game developer. Intended for single-player use, not online or leaderboard play. This repository **contains no game files**; the installer patches your own local game installation.

## Features

- **F8 — Probability panel** with three tabs. Rarity distributions total 100%; increasing one value proportionally reduces the others.
  - Slot rarity: Common / Uncommon / Rare / Legendary / Prismatic.
  - Fate Stone rarity, including quest rewards, shelves, and carried stones, with per-stone settings.
  - Class symbols: Warrior / Archer / Spearman / Cavalry / Mage / Duelist, plus Joker (0–5%, capped by the game).
  - Presets: Original / Hard / Medium / Easy / Roguelike Fun.
- **F7 — Utilities panel**: edit and optionally lock gold, blue essence, remaining spins, and hearts; adjust extra nudges. Includes free spins, free rerolls, unlimited nudges, guaranteed Joker chains, unlimited unit health, a damage multiplier, and one-hit kills.
- **Configuration**: `SlotboundOddsMod.ini` supports weight multipliers and target probabilities, with validation. Configuration comments are in Chinese.
- **Logging**: `SlotboundOddsMod.log` records mod loading, configuration, and original versus modified probabilities.

> A weight multiplier is not a final probability multiplier. For example, multiplying a Legendary slot weight of 0.4% by five gives approximately 1.97%, not 2%.

The installer and in-game mod panels currently use Chinese. English documentation does not translate the interface. English names above are descriptive translations.

## Testing status

The current release is a standalone installer preview for Windows x64. Local packaged self-tests and GUI startup tests passed, as did a user test on another newer PC with development tools installed. GitHub Actions also builds and tests the packaged installer. Compatibility with older PCs without development tools remains unconfirmed; support for every older Windows version is not promised.

## Installation — Windows, no Python required

1. Download `SlotboundOddsMod_*.zip` from [Releases](https://github.com/TokioKaze/-Slotbound-OddsMod-/releases) and **extract the archive**.
2. Close the game and run **`SlotboundOddsModSetup.exe`**. Windows may show a SmartScreen prompt for the unsigned installer.
3. The installer attempts to locate the Steam game folder. If necessary, click **Browse (浏览…)** and select the folder containing `Slotbound.exe`.
4. Click **Install / Update (安装 / 更新)**. The installer validates the files and backs up the original as `Slotbound.dat.orig`.
5. Launch the game through Steam. No separate tool needs to stay running. Press **F8** or **F7** to open the panels.

The installer also offers **Restore Original (恢复原版)** and **Check Installation Status (检查安装状态)**.

<details><summary>Install from source / Build the installer</summary>

- Source installation requires Python 3: run `pip install cryptography`, then
  `python slotbound_odds_patcher.py "D:\SteamLibrary\steamapps\common\Slotbound"`.
  Use `--restore` to restore the original or `--status` to check installation status. Alternatively, place the repository files in the game folder and run `Install.bat`.
- On Windows, run `Build.bat` to create the single-file executable at `dist/SlotboundOddsModSetup.exe`.
- GitHub Actions builds, tests, and publishes a preview release when `RELEASE_VERSION` changes on `main`, a matching `v*` tag is pushed, or the workflow is run manually. Tags must match `RELEASE_VERSION`.

</details>

## Uninstall / Restore the original

- Close the game and click **Restore Original** in the installer; or
- In Steam, right-click Slotbound → Properties → Installed Files → **Verify integrity of game files**.

## After game updates

Steam updates may replace patched files. Check mod compatibility before reinstalling; a newer game version may require an updated mod. Do not manually restore an old backup over a newer game installation.

## How it works

The game uses LÖVE 11.5 and LuaJIT, with code stored in an encrypted `Slotbound.dat`. The patcher decrypts this file locally, replaces `src/game/luck.lua` with a small loader that runs the mod and the original module, updates the game's integrity hash chain, and re-encrypts and verifies the package. The mod wraps the game's probability tables and functions. See [docs/UserGuide.md](docs/UserGuide.md) for details (Chinese).

## Repository files

| File | Purpose |
|---|---|
| `SlotboundOddsMod.lua` | Mod implementation |
| `slotbound_odds_patcher.py` | Decryption, patching, encryption, verification, backup and restore; command-line interface |
| `SlotboundOddsModInstaller.py` | GUI installer, packaged as `SlotboundOddsModSetup.exe` |
| `SlotboundOddsMod.ini` | Example configuration with Chinese comments |
| `Build.bat` / `.github/workflows/release.yml` | Local and CI installer builds |
| `Install.bat` / `RestoreOriginal.bat` | Source-based installation and restoration; Python required |
| `README_FIRST_ZH.txt` / `README_FIRST_EN.txt` | Chinese and English quick-start guides included in releases |
| `docs/UserGuide.md` | Detailed mechanics, configuration, scope, and validation notes |

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 TokioKaze

## Installation guides

[English](README_FIRST_EN.txt) · [中文](README_FIRST_ZH.txt)

Different file modification dates are normal. This repository contains one complete source version; use Git commits and release tags to identify versions.

========

作者：**TokioKaze** · 当前版本 **v1.3.1** · 适配游戏 **Slotbound v1.0.0(9)**（Steam 版）

一个本地单人用的 Slotbound Mod：自由调整老虎机与命运石的**稀有度概率**、**职业符号概率**，并提供一个功能面板（金币、精华、旋转次数、无限微调、必出小丑连线等）。

> 非官方 Mod，与游戏开发者无关。仅供单人游玩，请勿用于任何联网/排行榜场景。本仓库**不包含任何游戏文件**，安装时在你自己的正版游戏上现场打补丁。

## 功能

- **F8 概率面板**（三页，滑条合计恒为 100%，拉高一项其余按比例自动下降）
  - 局内老虎机稀有度：普通 / 高级 / 稀有 / 传说 / 棱彩
  - 命运石稀有度（含任务奖励、货架、携带的命运石，可逐块石头单独设置）
  - 职业符号概率：战士 / 弓手 / 枪兵 / 骑兵 / 法师 / 决斗者 + 小丑（0~5%，游戏硬上限）
  - 预设一键切换：原版 / 困难 / 中等 / 简单 / 肉鸽纯爽
- **F7 功能面板**：金币、蓝色精华、剩余旋转次数、红心、额外微调次数自由输入（可锁定）；
  免费旋转、免费重掷、无限微调、必出小丑连线（用于解锁小丑图鉴）、小兵无限血量、伤害倍率、一击必杀
- **配置文件** `SlotboundOddsMod.ini`（中文注释）：倍率模式（权重 × N）与目标概率模式（直接指定最终概率），带完整校验
- **日志** `SlotboundOddsMod.log`：确认 Mod 已加载、读到的配置、每处“原始 → 修改后”的实际概率

> 注意：倍率模式是“权重倍率”，不等于最终概率倍率。例如老虎机传说 0.4% 的权重 ×5，最终约 1.97%，而不是 2%。

## 验证状态

当前发布为单文件安装器测试版，Windows x64。已通过本机成品自检、窗口启动测试，以及用户在另一台带编程环境的新电脑上的运行测试。尚未验证无编程环境的旧电脑兼容性，不承诺支持所有旧 Windows 系统。

## 安装（Windows，无需 Python）

1. 从 [Releases](https://github.com/TokioKaze/-Slotbound-OddsMod-/releases) 下载最新的 `SlotboundOddsMod_*.zip`，**完整解压**。
2. 关闭游戏，双击 **`SlotboundOddsModSetup.exe`**。
   （未签名程序，Windows 可能弹出 SmartScreen 提示：点“更多信息”→“仍要运行”。）
3. 安装器会自动找到 Steam 里的游戏目录；没找到就点“浏览…”选择有 `Slotbound.exe` 的文件夹。
4. 点 **安装 / 更新**。安装器会先校验并备份原版为 `Slotbound.dat.orig`。
5. 首次安装完成后，无需额外开启工具，之后直接从 Steam 启动游戏即可。按 **F8** / **F7** 打开面板。

安装器还有 **恢复原版** 和 **检查安装状态** 两个按钮。

<details><summary>从源码安装 / 自己构建安装器</summary>

- 源码安装（需要 Python 3）：`pip install cryptography`，然后
  `python slotbound_odds_patcher.py "D:\SteamLibrary\steamapps\common\Slotbound"`
  （`--restore` 恢复原版，`--status` 检查状态）。也可以把仓库文件放进游戏目录后双击 `Install.bat`。
- 构建安装器：在 Windows 上双击 `Build.bat`（PyInstaller 单文件模式，产物为 `dist/SlotboundOddsModSetup.exe`）。
  推送 `v*` 标签时，GitHub Actions（`.github/workflows/release.yml`）会自动构建、自检并把 zip 附到 Release。
</details>

## 卸载 / 恢复原版

- 关闭游戏，在安装器里点 **恢复原版**；或
- Steam 右键 Slotbound → 属性 → 已安装文件 → **验证游戏文件的完整性**。

## 游戏更新后

Steam 更新会覆盖补丁文件，Mod 自动失效，游戏照常运行。新版本需要重新适配（打包器只接受已适配的版本，版本不符会直接报错，不会写坏文件）。

## 工作原理（简述）

游戏是 LÖVE 11.5 + LuaJIT，代码打包在加密的 `Slotbound.dat` 中。打包器在你本机解密该文件，把其中 `src/game/luck.lua` 换成一个很小的加载器（先运行 Mod，再运行原模块），同步更新游戏自带的完整性校验链，然后重新加密并完整回读校验。Mod 只通过代理/包装游戏自己的概率表和函数生效，不改动其它游戏文件。详见 [docs/UserGuide.md](docs/UserGuide.md)。

## 文件说明

| 文件 | 作用 |
|---|---|
| `SlotboundOddsMod.lua` | Mod 本体 |
| `slotbound_odds_patcher.py` | 核心：解密 / 打补丁 / 重新加密 / 校验 / 备份与恢复，也是命令行工具 |
| `SlotboundOddsModInstaller.py` | 图形安装器（打包成 `SlotboundOddsModSetup.exe`） |
| `SlotboundOddsMod.ini` | 示例配置（中文注释） |
| `Build.bat` / `.github/workflows/release.yml` | 本地 / CI 构建安装器 |
| `Install.bat` / `RestoreOriginal.bat` | 源码方式的安装与恢复（需要 Python） |
| `README_FIRST_ZH.txt` / `README_FIRST_EN.txt` | 随发布包分发的简短安装说明 |
| `docs/UserGuide.md` | 完整说明：抽取机制、受影响范围、配置、验证情况 |

## 更新日志

见 [CHANGELOG.md](CHANGELOG.md)。

## 许可

[MIT](LICENSE) © 2026 TokioKaze

## 安装说明 / Installation guides

[中文](README_FIRST_ZH.txt) · [English](README_FIRST_EN.txt)

文件修改日期不同是正常的：本仓库保存一套完整源码；以 Git 提交和 Release 标签识别版本。
