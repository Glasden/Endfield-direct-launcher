# Endfield Direct Launcher

直接启动《明日方舟：终末地》游戏本体，跳过“请通过官方启动器打开游戏”的拦截。

Launch the *Arknights: Endfield* game client directly, bypassing the
"请通过官方启动器打开游戏 / Open the game via the official launcher" gate.

> **非官方项目 · Unofficial project**
> 与上海鹰角网络科技有限公司无任何关联。本工具不修改游戏文件、不注入进程、
> 不读写游戏内存、不劫持网络流量，只影响**启动阶段的一次父进程校验**。
> 使用可能违反游戏用户协议，**账号风险自负**。
>
> Not affiliated with Shanghai Hypergryph Network Technology Co., Ltd. This tool does
> **not** modify game files, inject code, touch game memory, or intercept network
> traffic. It only influences the **one-time parent-process check at launch**.
> Using it may violate the game's terms of service — **use at your own risk**.

---

## 它解决什么问题 / What it solves

直接双击 `Endfield.exe` 会弹出：

> 游戏启动失败 —— 请通过官方启动器打开游戏

原因是游戏内置的 `OneChannelLC` 模块会检查**是谁启动了它**：父进程必须是官方启动器
`Games.exe`，且该文件必须能通过 Windows Authenticode 签名校验。命令行参数无法绕开
这个检查（它发生在参数被解析之前），用 `cmd /c start` 启动也不行（父进程变成 `cmd.exe`）。

这个工具的做法是：**挂起一个真实的、带鹰角签名的 `Games.exe` 作为“临时父进程”**，
再让 `Endfield.exe` 以它为父进程启动 —— 签名是真的，界面不会出现，校验通过后挂起进程立刻回收。

详见 [docs/how-it-works.md](docs/how-it-works.md)（包含逆向观察到的错误码与日志格式）。

---

## 环境要求 / Requirements

- Windows 10 / 11（x64）
- 已安装官方“鹰角启动器”，且游戏已下载完成
- 无需额外运行时（`.NET Framework 4.x` 与 `PowerShell 5.1` 是系统自带的）

> Linux / macOS / Steam Deck 不支持：本工具依赖 Windows 的进程创建语义。

---

## 快速开始 / Quick start

```powershell
git clone https://github.com/Glasden/Endfield-direct-launcher.git
cd Endfield-direct-launcher
powershell -ExecutionPolicy Bypass -File install.ps1
```

或者直接双击 `install.bat`。安装完成后**双击桌面上的「终末地」**即可启动。

默认是 **UAC 模式**：每次启动会请求一次管理员权限（与官方启动器本身的行为一致），
因为 `Endfield.exe` 的清单里就是 `requireAdministrator`，这一点绕不开。

### 免 UAC 模式（可选）

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode Task
```

会注册一个“最高权限、无触发器、仅当前用户登录时运行”的计划任务
`EndfieldDirectLaunch`。之后启动器通过 `schtasks /run` 触发它，**全程不再出现 UAC**。

> ⚠️ **安全权衡**：这等于对这条链路跳过了 UAC 确认。任何能执行该任务的程序都能借此
> 获得管理员权限执行 `Start-Endfield.ps1`。仅在你自己完全可控的机器上使用。
> 这也是为什么默认模式是 UAC 而不是 Task。

```
默认 (Uac)   双击 → Start-Endfield.exe → (无任务) → Start-Endfield.ps1 → UAC → 游戏
免 UAC (Task) 双击 → Start-Endfield.exe → schtasks /run → 计划任务(最高权限) → Start-Endfield.ps1 → 游戏
```

---

## 常用参数 / Options

```powershell
# 手动指定启动器目录（注册表探测失败时）
.\install.ps1 -LauncherRoot "D:\Hypergryph Launcher"

# 只装 UAC 模式（移除已存在的计划任务）
.\install.ps1 -Mode Uac

# 卸载：删除计划任务 + 桌面快捷方式 + 安装目录
.\install.ps1 -Uninstall

# 不想用 exe / 只想用脚本
powershell -ExecutionPolicy Bypass -File src\Start-Endfield.ps1
```

`src\Start-Endfield.ps1` 支持：

| 参数 | 说明 |
|---|---|
| `-GameExe` | 游戏本体路径（默认自动探测） |
| `-ParentPath` | 作为父进程的可执行文件（默认取最新带签名的 `Games.exe`） |
| `-LauncherRoot` | 鹰角启动器安装根目录（默认从注册表 `hypergryphlauncher-*` 协议探测） |
| `-GameArgs` | 传给游戏本体的附加参数 |
| `-NoElevate` | 不自动提权（调试） |
| `-KeepParent` | 校验通过后保留挂起父进程（调试） |
| `-TimeoutSeconds` | 等待启动校验的秒数，默认 90 |

首次成功启动后会把 `LauncherRoot / GameExe / ParentPath` 写进
`<安装目录>\Start-Endfield.config.json`，下次直接复用（启动器升级后会自动重新探测）。

---

## 目录结构 / Layout

```
Endfield-direct-launcher/
├─ install.ps1                    安装 / 卸载（含构建、计划任务、桌面快捷方式）
├─ install.bat                    双击安装入口
├─ src/
│  ├─ Start-Endfield.ps1          核心：挂起父进程 + 启动游戏 + 盯日志
│  └─ EndfieldLauncher.cs         无窗口启动器（/target:winexe）
├─ build/build.ps1                用系统自带的 csc.exe 编译 dist\Start-Endfield.exe
├─ launchers/start-endfield.bat   免安装直接运行（UAC 模式）
└─ docs/
   ├─ how-it-works.md             原理与逆向观察（错误码 / 日志格式）
   └─ troubleshooting.md          出问题怎么查
```

安装后的文件在 `%LOCALAPPDATA%\Programs\EndfieldDirect\`。

> 仓库**不包含**任何鹰角的二进制或美术资源。图标在构建时从你本机的启动器目录
> （`<launcher>\<版本>\res\icons\endfield.ico`）现取，取不到就不嵌图标。

---

## 已知限制 / Limitations

- 依赖服务端下发的启动校验配置（`gameLaunchCheck`）与启动器的代码签名；官方更新后可能失效。
- 只支持官方启动器安装的游戏，不支持 Steam / Epic / 主机版本。
- 启动器必须保持安装状态（签名校验要用它的 `Games.exe`）。
- 游戏本体需要管理员权限；不提供“降权运行”的路径（实测反作弊相关组件依赖管理员上下文）。

---

## 常见问题 / FAQ

**Q：双击后没反应？**
A：先看 `%TEMP%\Start-Endfield.log` 和 `docs/troubleshooting.md`。

**Q：还是弹“请通过官方启动器打开游戏”？**
A：看 `%USERPROFILE%\AppData\LocalLow\Hypergryph\Endfield\sdklogs\OneChannelLC.log`：
`errorCode 10100` 说明父进程身份不匹配（启动器可能换了路径），`10101` 说明签名校验失败
（启动器被换掉/损坏）。两种情况都可以用 `-ParentPath` 手动指定带签名的 `Games.exe`。

**Q：会不会动我游戏里的东西？**
A：不会。脚本只做两件事：创建进程、读日志。不写游戏目录、不改注册表（除安装计划任务/快捷方式）。

**Q：会被封号吗？**
A：不知道。它不修改游戏、不注入、不自动化操作，但确实绕过了官方的一个启动校验。
如果你介意，请使用官方启动器。

---

## 致谢 / Credits

- [ok-ef](https://github.com/AliceJump/ok-end-field) —— 公开项目，采用了同样“挂起官方
  `Games.exe` 作为临时父进程”的思路，可作为本方案可行性的旁证。
- 原理分析基于游戏自身日志（`OneChannelLC.log` / `u8sdk_pc.log`）的可观测行为。

## License

[MIT](LICENSE)（仅覆盖本仓库代码；不包含任何第三方的游戏文件或美术资源）。
