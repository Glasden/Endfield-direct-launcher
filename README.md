# Endfield Direct Launcher

直接启动《明日方舟：终末地》游戏本体，跳过“请通过官方启动器打开游戏”的拦截。

[English](README.en.md) | **简体中文**

> **非官方项目**
> 与上海鹰角网络科技有限公司无任何关联。本工具不修改游戏文件、不注入进程、不读写游戏内存、
> 不劫持网络流量，只影响**启动阶段的一次父进程校验**。
> 使用可能违反游戏用户协议，**账号风险自负**。

---

## 它解决什么问题

直接双击 `Endfield.exe` 会弹出：

> 游戏启动失败 —— 请通过官方启动器打开游戏

原因是游戏内置的 `OneChannelLC` 模块会检查**是谁启动了它**：

1. 父进程必须是官方启动器 `Games.exe`；
2. 该文件必须能通过 **Windows Authenticode 签名校验**（由鹰角签名）。

命令行参数改变不了这一点（提权与校验发生在参数被解析之前），用 `cmd /c start` 也不行
——父进程会变成 `cmd.exe`。

本工具的做法是：先以**挂起状态**启动一个真实的、带鹰角签名的 `Games.exe` 作为“临时父进程”，
再让 `Endfield.exe` 以它为父进程创建；等游戏日志出现 `Parent process check success:<pid>`
后立刻回收挂起进程。**全程不改动任何游戏文件。**

原理与错误码见 [docs/zh-CN/how-it-works.md](docs/zh-CN/how-it-works.md)。

---

## 环境要求

- Windows 10 / 11（x64）
- 已安装官方鹰角启动器，且游戏已下载完成
- 无需额外运行时：PowerShell 5.1 与 .NET Framework 4.x 都是系统自带

> 不支持 Linux / macOS / Steam Deck：本工具依赖 Windows 特有的进程创建语义。

---

## 快速开始

```powershell
git clone https://github.com/Glasden/Endfield-direct-launcher.git
cd Endfield-direct-launcher
powershell -ExecutionPolicy Bypass -File install.ps1
```

也可以直接双击 `install.bat`。安装完成后**双击桌面上的「终末地」**即可启动。

默认是 **UAC 模式**：每次启动请求一次管理员权限，与官方启动器本身的行为一致。
这一条绕不开——`Endfield.exe` 的清单里就是 `requireAdministrator`，进程只能以提权方式创建。

### 免 UAC 模式（可选）

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode Task
```

会注册计划任务 `EndfieldDirectLaunch`：最高权限、仅当前用户登录时运行、无触发器。
启动器通过 `schtasks /run` 触发它，于是**全程不再出现 UAC 提示**。

> ⚠️ **安全权衡**：这等于对这条链路跳过了 UAC 确认。任何能执行该任务的程序，都能借此以
> 管理员权限运行 `Start-Endfield.ps1`。仅在你自己完全可控的机器上使用。
> 这也是默认模式是 `Uac` 而不是 `Task` 的原因。

```
默认 (Uac)    双击 → Start-Endfield.exe →（无任务）→ Start-Endfield.ps1 → UAC → 游戏
免 UAC (Task) 双击 → Start-Endfield.exe → schtasks /run → 计划任务（最高权限）→ Start-Endfield.ps1 → 游戏
```

---

## 参数

```powershell
# 注册表探测失败时手动指定启动器目录
.\install.ps1 -LauncherRoot "D:\Hypergryph Launcher"

# 只装 UAC 模式（会移除已存在的计划任务）
.\install.ps1 -Mode Uac

# 卸载：计划任务 + 桌面快捷方式 + 安装目录
.\install.ps1 -Uninstall

# 完全不用 exe，直接跑脚本
powershell -ExecutionPolicy Bypass -File src\Start-Endfield.ps1
```

`src\Start-Endfield.ps1` 参数：

| 参数 | 说明 |
|---|---|
| `-GameExe` | 游戏本体路径（默认自动探测） |
| `-ParentPath` | 作为父进程的可执行文件（默认取最新带签名的 `Games.exe`） |
| `-LauncherRoot` | 鹰角启动器安装根目录（默认通过 `hypergryphlauncher-*` 协议探测） |
| `-GameArgs` | 传给游戏本体的附加参数 |
| `-NoElevate` | 不自动提权（调试用） |
| `-KeepParent` | 校验通过后保留挂起父进程（调试用） |
| `-TimeoutSeconds` | 等待启动校验的秒数，默认 90 |

首次成功启动后，会把 `LauncherRoot / GameExe / ParentPath` 写进
`<安装目录>\Start-Endfield.config.json` 供下次复用；启动器升级后会自动重新探测。

---

## 目录结构

```
Endfield-direct-launcher/
├─ install.ps1                    安装 / 卸载（构建、计划任务、快捷方式）
├─ install.bat                    双击安装入口
├─ src/
│  ├─ Start-Endfield.ps1          核心：挂起父进程 + 启动游戏 + 盯日志
│  └─ EndfieldLauncher.cs         无窗口启动器（/target:winexe）
├─ build/build.ps1                用系统自带的 csc.exe 编译 dist\Start-Endfield.exe
├─ launchers/start-endfield.bat   免安装直接运行（UAC 模式）
└─ docs/
   ├─ zh-CN/
   │  ├─ how-it-works.md          原理与逆向观察（错误码 / 日志格式）
   │  └─ troubleshooting.md       出问题怎么查
   └─ en/
      ├─ how-it-works.md
      └─ troubleshooting.md
```

安装后的文件在 `%LOCALAPPDATA%\Programs\EndfieldDirect\`。

> 仓库**不包含**任何鹰角的二进制或美术资源。图标在构建时从你本机的启动器目录
> （`<launcher>\<版本>\res\icons\endfield.ico`）现取；取不到就不嵌图标。

---

## 已知限制

- 依赖服务端下发的启动校验配置（`gameLaunchCheck`）与启动器的代码签名；官方更新后可能失效。
- 只支持通过官方鹰角启动器安装的游戏。
- 启动器必须保持安装状态——签名校验要用它的 `Games.exe`。
- 游戏本体需要管理员权限；不提供“降权运行”的路径（反作弊相关组件依赖管理员上下文）。

---

## 常见问题

**双击后没反应？**
先看 `%TEMP%\Start-Endfield.log` 和 [docs/zh-CN/troubleshooting.md](docs/zh-CN/troubleshooting.md)。

**还是弹“请通过官方启动器打开游戏”？**
看 `%USERPROFILE%\AppData\LocalLow\Hypergryph\Endfield\sdklogs\OneChannelLC.log` 的末尾：
`errorCode 10100` 表示父进程身份不匹配（启动器可能换了路径），`10101` 表示签名校验失败
（启动器被替换或损坏）。两种都可以用 `-ParentPath` 手动指定一个带有效签名的 `Games.exe`。

**会不会动我的游戏安装目录？**
不会。脚本只创建进程、读日志；不写游戏目录。对系统的改动只有可选的计划任务和桌面快捷方式。

**会被封号吗？**
不知道。它不修改游戏、不注入、不自动化操作，但确实绕过了官方的一次启动校验。
如果介意，请使用官方启动器。

---

## 致谢

- [ok-ef](https://github.com/AliceJump/ok-end-field) —— 公开项目，采用了同样“挂起官方
  `Games.exe` 作为临时父进程”的思路，可作为本方案可行性的旁证。
- 原理分析基于游戏自身日志（`OneChannelLC.log` / `u8sdk_pc.log`）的可观测行为。

## License

[MIT](LICENSE)（仅覆盖本仓库代码；不包含任何第三方的游戏文件或美术资源）。
