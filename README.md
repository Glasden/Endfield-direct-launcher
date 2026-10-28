# Endfield Direct Launcher

Launch *Arknights: Endfield* directly and skip the
"请通过官方启动器打开游戏 / Open the game via the official launcher" gate.

**English** | [简体中文](README.zh-CN.md)

> **Unofficial project**
> Not affiliated with Shanghai Hypergryph Network Technology Co., Ltd.
> This tool does **not** modify game files, inject code, touch game memory, or intercept
> network traffic. It only influences the **one-time parent-process check at launch**.
> Using it may violate the game's terms of service — **use at your own risk**.

---

## The problem

Double-clicking `Endfield.exe` shows:

> 游戏启动失败 —— 请通过官方启动器打开游戏
> *(Game launch failed — please open the game via the official launcher)*

The game ships a module (`OneChannelLC`) that verifies **who launched it**:

1. the parent process must be the official launcher (`Games.exe`), and
2. that executable must pass **Windows Authenticode verification** (signed by Hypergryph).

Command-line flags can't change this — elevation and verification happen before any
argument is parsed. `cmd /c start` doesn't help either: the parent simply becomes `cmd.exe`.

What this tool does instead: it starts a **suspended** copy of the genuine, signed
`Games.exe` as a temporary parent, creates `Endfield.exe` with that process as its parent,
then reaps the suspended process as soon as the game logs
`Parent process check success:<pid>`. **No game file is modified.**

See [docs/how-it-works.md](docs/how-it-works.md) for the observed error codes and log
samples (document currently in Chinese — translations are welcome).

---

## Requirements

- Windows 10 / 11 (x64)
- Official Hypergryph launcher installed, game downloaded
- No extra runtime: PowerShell 5.1 and .NET Framework 4.x are built into Windows

> Not supported: Linux / macOS / Steam Deck — the tool relies on Windows-specific
> process creation semantics.

---

## Quick start

```powershell
git clone https://github.com/Glasden/Endfield-direct-launcher.git
cd Endfield-direct-launcher
powershell -ExecutionPolicy Bypass -File install.ps1
```

Or just double-click `install.bat`. When it finishes, double-click the **终末地**
shortcut on your desktop.

The default is **UAC mode**: one elevation prompt per launch, exactly like the official
launcher. This is unavoidable — `Endfield.exe` declares `requireAdministrator` in its
manifest, so the process can only be created elevated.

### No-UAC mode (optional)

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode Task
```

Registers a scheduled task `EndfieldDirectLaunch` that runs with the highest privileges
(run-only-when-logged-on, no trigger). The launcher then triggers it via `schtasks /run`,
so **no UAC prompt ever appears**.

> ⚠️ **Security trade-off**: this skips the UAC confirmation for this code path. Any
> program able to run that task can use it to execute `Start-Endfield.ps1` with admin
> rights. Only do this on a machine you fully control. That is why the default mode is
> `Uac`, not `Task`.

```
default (Uac)   double-click → Start-Endfield.exe → (no task) → Start-Endfield.ps1 → UAC → game
no-UAC (Task)   double-click → Start-Endfield.exe → schtasks /run → task (highest) → Start-Endfield.ps1 → game
```

---

## Options

```powershell
# Explicit launcher directory (when registry detection fails)
.\install.ps1 -LauncherRoot "D:\Hypergryph Launcher"

# UAC mode only (removes an existing scheduled task)
.\install.ps1 -Mode Uac

# Uninstall: scheduled task + desktop shortcut + install directory
.\install.ps1 -Uninstall

# Skip the EXE entirely and use the script directly
powershell -ExecutionPolicy Bypass -File src\Start-Endfield.ps1
```

`src\Start-Endfield.ps1` parameters:

| Parameter | Description |
|---|---|
| `-GameExe` | Path to the game executable (auto-detected by default) |
| `-ParentPath` | Executable used as parent process (defaults to the newest signed `Games.exe`) |
| `-LauncherRoot` | Hypergryph launcher root (auto-detected via the `hypergryphlauncher-*` URL protocol) |
| `-GameArgs` | Extra arguments forwarded to the game |
| `-NoElevate` | Never self-elevate (debugging) |
| `-KeepParent` | Keep the suspended parent process after a successful check (debugging) |
| `-TimeoutSeconds` | Seconds to wait for the launch check (default 90) |

After the first successful launch, the resolved `LauncherRoot / GameExe / ParentPath` are
cached in `<install dir>\Start-Endfield.config.json` and reused next time; the launcher is
re-detected automatically when it updates.

---

## Layout

```
Endfield-direct-launcher/
├─ install.ps1                    install / uninstall (build, task, shortcut)
├─ install.bat                    double-click entry point
├─ src/
│  ├─ Start-Endfield.ps1          core: suspended parent + launch + log watch
│  └─ EndfieldLauncher.cs         windowless stub (/target:winexe)
├─ build/build.ps1                compiles dist\Start-Endfield.exe with the built-in csc.exe
├─ launchers/start-endfield.bat   run without installing (UAC mode)
└─ docs/
   ├─ how-it-works.md             internals: error codes and log formats
   └─ troubleshooting.md          symptom → cause → fix
```

Installed files live in `%LOCALAPPDATA%\Programs\EndfieldDirect\`.

> The repository contains **no** Hypergryph binaries or artwork. The icon is read at build
> time from your own launcher installation
> (`<launcher>\<version>\res\icons\endfield.ico`); if it isn't found, the EXE is built
> without an icon.

---

## Limitations

- Depends on the server-delivered launch-check config (`gameLaunchCheck`) and on the
  launcher's code signature; an official update can break it.
- Only supports games installed through the official Hypergryph launcher.
- The launcher must stay installed — its signed `Games.exe` is what the check verifies.
- The game requires administrator rights; there is no "run unelevated" path (anti-cheat
  components expect an elevated context).

---

## FAQ

**Double-clicking does nothing.**
Check `%TEMP%\Start-Endfield.log` and [docs/troubleshooting.md](docs/troubleshooting.md).

**It still says "open the game via the official launcher".**
Look at the tail of
`%USERPROFILE%\AppData\LocalLow\Hypergryph\Endfield\sdklogs\OneChannelLC.log`:
`errorCode 10100` means the parent process identity didn't match (the launcher may have
moved), `10101` means the signature check failed (launcher replaced or corrupted). Both can
be worked around by pointing `-ParentPath` at a valid signed `Games.exe`.

**Does it touch my game installation?**
No. The script only creates a process and reads log files. It does not write to the game
directory; the only system changes are the optional scheduled task and the desktop shortcut.

**Can I get banned?**
Unknown. It does not modify the game, inject code, or automate gameplay, but it does bypass
one official launch check. If that bothers you, use the official launcher.

---

## Credits

- [ok-ef](https://github.com/AliceJump/ok-end-field) — a public project that uses the same
  "suspended official `Games.exe` as temporary parent" technique, which corroborates that
  the approach works.
- The analysis is based on observable behaviour in the game's own logs
  (`OneChannelLC.log`, `u8sdk_pc.log`).

## License

[MIT](LICENSE) — covers this repository's code only; it includes no third-party game files
or artwork.
