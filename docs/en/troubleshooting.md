# Troubleshooting

## Where to look first

| What | Where |
|---|---|
| The launcher's own log | `%TEMP%\Start-Endfield.log` |
| The game's launch-check log | `%USERPROFILE%\AppData\LocalLow\<company>\Endfield\sdklogs\OneChannelLC.log` |
| SDK log (contains `launch check result`) | `%USERPROFILE%\AppData\LocalLow\<company>\Endfield\sdklogs\u8sdk_pc.log` |
| Install directory | `%LOCALAPPDATA%\Programs\EndfieldDirect\` |
| Scheduled task | `schtasks /query /tn EndfieldDirectLaunch /v /fo LIST` |
| Cached config | `%LOCALAPPDATA%\Programs\EndfieldDirect\Start-Endfield.config.json` |

`<company>` is the first line of `Endfield_Data\app.info`: `Hypergryph` (CN) or
`Gryphline` (global).

---

## Symptom table

### 1. Double-clicking the shortcut does nothing

- Confirm the install exists: `%LOCALAPPDATA%\Programs\EndfieldDirect\` should contain both
  `Start-Endfield.exe` and `Start-Endfield.ps1`.
- Not installed / installed into a restricted folder: re-run `install.ps1` (it installs into
  `%LOCALAPPDATA%`).
- Blocked by antivirus: whitelist the install directory. The launcher is an unsigned
  windowless EXE and is fairly easy to misreport.
- Scheduled task removed but you installed with `-Mode Task`: the EXE falls back to
  `Start-Endfield.ps1` (which will prompt for UAC once). If that still does nothing, run it
  directly and read the error:
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\EndfieldDirect\Start-Endfield.ps1"
  ```

### 2. It still says "open the game via the official launcher"

Look at the tail of `OneChannelLC.log`:

```
Not found matched name                      -> errorCode 10100
Parent process verify signature failed:...  -> errorCode 10101
```

- **10100**: parent identity mismatch. The launcher usually moved or was renamed. Specify it
  manually:
  ```powershell
  .\src\Start-Endfield.ps1 -ParentPath "<launcher>\<version>\Games.exe" -LauncherRoot "<launcher>"
  ```
- **10101**: signature verification failed. Check it:
  ```powershell
  Get-AuthenticodeSignature "<launcher>\<version>\Games.exe" | Format-List Status,SignerCertificate
  ```
  If `Status` is not `Valid`, the file was modified or corrupted → repair/reinstall the
  official launcher.

### 3. It asks for UAC on every launch

That's the default `Uac` mode. Switch:
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode Task
```

### 4. No-UAC mode stopped working (UAC prompt is back)

- The scheduled task was removed/disabled (clean-up tools love doing that):
  ```powershell
  schtasks /query /tn EndfieldDirectLaunch
  ```
  If it's missing, re-run `install.ps1 -Mode Task`.
- The install directory moved: the task stores an absolute script path — reinstall.

### 5. The game starts but exits immediately

- Check the tail of `%TEMP%\Start-Endfield.log` for "the game process exited during the
  check".
- If it's an anti-cheat or GPU error, first confirm the game still launches normally
  **through the official launcher**.

### 6. A console window flashes

- Only `launchers\start-endfield.bat` and `install.bat` open a console; the desktop shortcut
  points at `Start-Endfield.exe` (`/target:winexe`) and should not flash anything.
- If you see a black box, the shortcut probably still points at a `.bat` — re-run
  `install.ps1` to recreate it.

---

## Manual end-to-end verification

```powershell
# 1) does the candidate parent have a valid signature?
Get-AuthenticodeSignature "<launcher>\<version>\Games.exe" | Select-Object Status

# 2) does the scheduled task exist, and what does it point at?
(Get-ScheduledTask -TaskName EndfieldDirectLaunch).Actions

# 3) run the script in the foreground (full output)
powershell -Verbose -ExecutionPolicy Bypass -File "<install dir>\Start-Endfield.ps1"

# 4) check the result
Get-Content "$env:USERPROFILE\AppData\LocalLow\Hypergryph\Endfield\sdklogs\OneChannelLC.log" -Tail 6
```

`Parent process check success:<pid>` means the parent-process gate passed.

---

## When opening an issue, please include

1. the last 20 lines of `%TEMP%\Start-Endfield.log`;
2. the last 10 lines of `OneChannelLC.log`;
3. the output of `Get-AuthenticodeSignature` for `Games.exe`;
4. your Windows version (`winver`) and the launcher version
   (file version of `<launcher>\Launcher.exe`).

**Do not** attach account details, full personal paths, or any keys.
