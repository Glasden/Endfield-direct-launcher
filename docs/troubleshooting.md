# 排查指南 / Troubleshooting

## 先看这几个地方

| 内容 | 位置 |
|---|---|
| 启动器自身日志 | `%TEMP%\Start-Endfield.log` |
| 游戏启动校验日志 | `%USERPROFILE%\AppData\LocalLow\<公司>\Endfield\sdklogs\OneChannelLC.log` |
| SDK 日志（含 launch check result） | `%USERPROFILE%\AppData\LocalLow\<公司>\Endfield\sdklogs\u8sdk_pc.log` |
| 安装目录 | `%LOCALAPPDATA%\Programs\EndfieldDirect\` |
| 计划任务 | `schtasks /query /tn EndfieldDirectLaunch /v /fo LIST` |
| 缓存的配置 | `%LOCALAPPDATA%\Programs\EndfieldDirect\Start-Endfield.config.json` |

`<公司>` 由 `Endfield_Data\app.info` 第一行决定：国服 `Hypergryph`，国际服 `Gryphline`。

---

## 症状对照表

### 1. 双击快捷方式没反应

- 先确认安装过：目录 `%LOCALAPPDATA%\Programs\EndfieldDirect\` 是否存在 `Start-Endfield.exe` 和 `Start-Endfield.ps1`。
- 没装过 / 装到了受限目录：重新跑 `install.ps1`（会把文件装到 `%LOCALAPPDATA%`）。
- 被杀软拦截：把安装目录加入白名单。启动器是无窗口的未签名 exe，容易被误报。
- 计划任务被删了但用的是 Task 模式：exe 会回退到 `Start-Endfield.ps1`（会弹一次 UAC）；
  若仍然没反应，直接跑：
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\EndfieldDirect\Start-Endfield.ps1"
  ```
  看控制台报错。

### 2. 还是弹“请通过官方启动器打开游戏”

看 `OneChannelLC.log` 最后几行：

```
Not found matched name                      -> errorCode 10100
Parent process verify signature failed:...  -> errorCode 10101
```

- **10100**：父进程身份不匹配。通常是启动器换了目录/文件名。手动指定：
  ```powershell
  .\src\Start-Endfield.ps1 -ParentPath "<launcher>\<版本>\Games.exe" -LauncherRoot "<launcher>"
  ```
- **10101**：签名校验失败。用 PowerShell 检查：
  ```powershell
  Get-AuthenticodeSignature "<launcher>\<版本>\Games.exe" | Format-List Status,SignerCertificate
  ```
  `Status` 不是 `Valid` 就说明文件被改动或损坏 → 重装/修复官方启动器。

### 3. 每次都要点一次 UAC

说明装的是默认的 `Uac` 模式。换免 UAC：
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode Task
```

### 4. 免 UAC 模式失效了（又开始弹 UAC）

- 计划任务被清理/被优化软件禁用：
  ```powershell
  schtasks /query /tn EndfieldDirectLaunch
  ```
  不存在就重跑 `install.ps1 -Mode Task`。
- 换过安装目录：任务里的脚本路径是绝对路径，重装即可。

### 5. 游戏起来了但立刻退出

- 看 `%TEMP%\Start-Endfield.log` 的最后几行，脚本是否报“游戏进程在校验阶段退出”。
- 若是反作弊/显卡相关报错，先确认**不经过本工具**直接开官方启动器能正常进入游戏。

### 6. 启动时有短暂的黑框

- 只有 `launchers\start-endfield.bat` 和 `install.bat` 会开控制台；桌面快捷方式指向的是
  `/target:winexe` 的 `Start-Endfield.exe`，不会有黑框。
- 如果看到黑框，说明快捷方式还在指向 bat，重跑 `install.ps1` 重建快捷方式。

---

## 手工验证整条链路

```powershell
# 1) 父进程候选是否带有效签名
Get-AuthenticodeSignature "<launcher>\<版本>\Games.exe" | Select-Object Status

# 2) 计划任务是否存在、动作指向哪里
(Get-ScheduledTask -TaskName EndfieldDirectLaunch).Actions

# 3) 直接跑脚本（前台，能看到全部输出）
powershell -Verbose -ExecutionPolicy Bypass -File "<安装目录>\Start-Endfield.ps1"

# 4) 校验结果
Get-Content "$env:USERPROFILE\AppData\LocalLow\Hypergryph\Endfield\sdklogs\OneChannelLC.log" -Tail 6
```

看到 `Parent process check success:<pid>` 就说明父进程那一关过了。

---

## 提 Issue 时请附上

1. `%TEMP%\Start-Endfield.log` 最后 20 行；
2. `OneChannelLC.log` 最后 10 行；
3. `Get-AuthenticodeSignature` 的输出（`Games.exe`）；
4. Windows 版本（`winver`）与启动器版本（`<launcher>\Launcher.exe` 的文件版本）。

**不要**附带账号信息、完整用户路径或任何密钥。
