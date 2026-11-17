# Slotbound 概率 Mod（转运军团 / Slotbound Odds Mod）

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
