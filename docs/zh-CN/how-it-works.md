# 原理：终末地的启动校验是怎么拦人的

> 本文所有结论来自对**运行日志**的观察与实验验证，没有反编译或修改任何游戏文件。
> 路径用 `<launcher>` 表示鹰角启动器安装根目录（例如 `E:\Hypergryph Launcher`）。

## TL;DR

`Endfield.exe` 启动后会加载 `OneChannelLC` 模块，它会检查**自己的父进程**：

1. 父进程可执行文件的身份要匹配官方启动器（名字 + 产品信息）；
2. 父进程文件必须能通过 **Windows Authenticode 签名校验**（必须由鹰角签名）。

任一不满足就弹“请通过官方启动器打开游戏”并退出。参数、`cmd`、重命名都绕不开，
唯一干净的做法是**让父进程真的变成那个官方启动器**。

---

## 1. 可观测的日志

两处日志是关键（都在 `%USERPROFILE%\AppData\LocalLow\<公司>\Endfield\sdklogs\`，
公司名由 `Endfield_Data\app.info` 第一行决定，国服是 `Hypergryph`）：

### `OneChannelLC.log` —— 校验本身的日志

```
[10-15 12:23:35.603] [info] [] [] [line:] [thread 0] ///////////////////////////OneChannelLC///////////////////////////
[10-15 12:23:35.603] [info] [] [] [line:] [thread 0] Add launch check:Launcher, 1, 2
[10-15 12:23:35.603] [info] [] [] [line:] [thread 0] Total launch check size:1
[10-15 12:23:35.681] [info] [] [] [line:] [thread 0] Parent process check success:61144
[10-15 12:23:35.681] [info] [] [] [line:] [thread 0] Record check result:{"code":2003,"msg":{"code":0,"msg":{"filePath":"e:\\hypergryph launcher\\1.6.0\\games.exe"}}}
```

失败的两种形态：

```
# 父进程不是启动器（比如 explorer.exe、maaend.exe）
[...] Not found matched name
[...] Record check result:{"code":2003,"msg":{"code":1,"msg":{"errorCode":10100,"filePath":"c:\\windows\\explorer.exe"}}}

# 名字对了，但文件签名无效（这里把一个 cmd.exe 副本改名成 games.exe 试的）
[...] Parent process verify signature failed:31540, 2148204800
[...] Record check result:{"code":2003,"msg":{"code":1,"msg":{"errorCode":10101,"filePath":"...\\games.exe"}}}
```

`2148204800` = `0x800B0100` = `TRUST_E_NOSIGNATURE`，即 **Windows Authenticode 校验失败**。

### `u8sdk_pc.log` —— SDK 层的调用与结果

```
[u8sdkimpl.cpp] [U8SDKImpl::U8StartLaunchCheck] [line:1295] Launch check result:{"code":2003,"msg":{"code":0,...}}
```

失败后游戏还会自己尝试拉起启动器：

```
[...] [U8SDKImpl::TryRunLauncher] [line:1073] Try run launcher success
```

它用的是官方深链：
`hypergryphlauncher-<appcode>://start?ta=endfield`
（`<appcode>` 是启动器的构建标识，从注册表
`HKLM\SOFTWARE\Classes\hypergryphlauncher-*\shell\open\command`
可以直接看到，形如 `"...\Launcher.exe" "%1"`）。

---

## 2. 错误码

| errorCode | 日志关键字 | 含义 |
|---|---|---|
| `0` | `Parent process check success:<pid>` | 通过 |
| `10100` | `Not found matched name` | 父进程身份不匹配（不是官方启动器） |
| `10101` | `Parent process verify signature failed` | 身份匹配但签名校验失败 |

注意 `filePath` 字段就是它判定时使用的**父进程镜像路径**，排查时很有用。

---

## 3. 被否决的几种“简单办法”

| 尝试 | 结果 | 原因 |
|---|---|---|
| 给 `Endfield.exe` 加参数（`--no-admin`、`-skip_uac` 等） | 无效 | UAC/提权来自 exe 清单，进程创建阶段就决定了，参数还没被解析 |
| `cmd /c start Endfield.exe` | `10100` | 父进程变成 `cmd.exe`，身份不匹配 |
| 把 `cmd.exe` 复制成 `games.exe` 再启动 | `10101` | 名字对了，但文件没有鹰角签名 |
| 直接改游戏文件让它不检查 | 不采用 | 会破坏文件完整性、可能触发反作弊，且属于修改游戏 |

结论：**签名是真的，身份是假的——只能借一个真实的官方进程来当父进程。**

---

## 4. 采用的方案：挂起的官方启动器作为临时父进程

```
CreateProcessW(Games.exe, CREATE_SUSPENDED)      -> 得到一个“活着但一行代码都没跑”的进程
CreateProcessW(Endfield.exe, STARTUPINFOEX{
     AttrList = PROC_THREAD_ATTRIBUTE_PARENT_PROCESS -> 上面那个进程
})
```

- `CREATE_SUSPENDED`：启动器的主函数永远不会执行，所以不会弹窗口、不会抢单实例锁；
- `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`：让新进程的父 PID 指向我们指定的进程句柄；
- 校验读的是**父进程的镜像路径与签名**，对挂起状态没有任何感知；
- 日志出现 `Parent process check success:<我们那个挂起进程的 PID>` 之后，直接
  `TerminateProcess` 回收它，游戏继续运行。

关键代码（`src/Start-Endfield.ps1` 内的 C# 片段）：

```csharp
// 1) 挂起启动父进程
CreateProcessW(parentExe, ..., CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, ...);

// 2) 属性列表：注意 lpValue 必须指向“保存句柄的内存”，不能直接传句柄值
IntPtr hValue = Marshal.AllocHGlobal(IntPtr.Size);
Marshal.WriteIntPtr(hValue, piParent.hProcess);
UpdateProcThreadAttribute(list, 0, (IntPtr)0x00020000 /* PARENT_PROCESS */,
                          hValue, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);

// 3) 用属性列表启动游戏
CreateProcessW(childExe, ..., EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, ...);
```

> 踩坑记录：`lpValue` 如果直接传 `hProcess`（句柄值本身），内核会把它当指针解引用，
> 表现为 `CreateProcessW` 里 `0xC0000005` 访问冲突。必须传“指向句柄的指针”。

### 时序

```
Start-Endfield.ps1
   │
   ├─ CreateProcessW(Games.exe, SUSPENDED)        pid=15568   不执行任何代码
   ├─ CreateProcessW(Endfield.exe, parent=15568)  pid=40748
   │
   ├─ 轮询 OneChannelLC.log ...
   │      └─ "Parent process check success:15568"   ← 校验通过
   ├─ TerminateProcess(15568)                       ← 回收挂起进程
   └─ exit 0                                        ← 游戏继续运行
```

失败时（比如签名失效）脚本会立即杀掉刚拉起的游戏进程，避免把“启动失败”的对话框留在屏幕上。

---

## 5. 为什么不走别的路

- **注入 / patch**：属于修改游戏进程或文件，触犯反作弊的概率高得多；
- **Hook `WinVerifyTrust`**：同样要注入，且是明确的对抗行为；
- **伪造签名**：不可行（需要鹰角私钥）；
- 本方案不写游戏目录、不改游戏文件、不碰游戏内存——影响范围只有“创建进程时的那一个父 PID”。

---

## 6. 什么情况下会失效

| 变化 | 现象 | 应对 |
|---|---|---|
| 启动器更新、`Games.exe` 路径变化 | `10100`（名字/身份不匹配） | 脚本会自动重新探测最新带签名的 `Games.exe`；也可 `-ParentPath` 指定 |
| 启动器被替换/损坏、签名无效 | `10101` | 修复/重装官方启动器 |
| 服务端把 `gameLaunchCheck` 改成更严格的校验 | 可能新增错误码 | 只能等社区重新分析 |
| 启动器改名为别的 exe | `10100` | 更新 `Get-ParentCandidates` 里的候选逻辑 |

排查入口永远是 `OneChannelLC.log` 的最后几行。
