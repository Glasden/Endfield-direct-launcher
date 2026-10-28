# How the launch check works

> Every conclusion below comes from observing **runtime logs** and from experiments —
> no decompilation and no modification of any game file.
> `<launcher>` stands for the Hypergryph launcher root directory
> (e.g. `E:\Hypergryph Launcher`).

## TL;DR

After `Endfield.exe` starts, it loads a module called `OneChannelLC` that inspects
**its own parent process**:

1. the parent executable's identity must match the official launcher, and
2. the parent file must pass **Windows Authenticode verification** (signed by Hypergryph).

If either check fails, the game shows "请通过官方启动器打开游戏" and exits. Command-line
arguments, `cmd`, and renaming executables cannot work around it — the only clean solution
is to make the parent process *actually be* the official launcher.

---

## 1. The observable logs

Two logs matter. Both live under
`%USERPROFILE%\AppData\LocalLow\<company>\Endfield\sdklogs\`; the company name is the first
line of `Endfield_Data\app.info` (`Hypergryph` for CN, `Gryphline` for the global client).

### `OneChannelLC.log` — the check itself

```
[10-15 12:23:35.603] [info] [] [] [line:] [thread 0] ///////////////////////////OneChannelLC///////////////////////////
[10-15 12:23:35.603] [info] [] [] [line:] [thread 0] Add launch check:Launcher, 1, 2
[10-15 12:23:35.603] [info] [] [] [line:] [thread 0] Total launch check size:1
[10-15 12:23:35.681] [info] [] [] [line:] [thread 0] Parent process check success:61144
[10-15 12:23:35.681] [info] [] [] [line:] [thread 0] Record check result:{"code":2003,"msg":{"code":0,"msg":{"filePath":"e:\\hypergryph launcher\\1.6.0\\games.exe"}}}
```

The two failure shapes:

```
# parent is not the launcher (e.g. explorer.exe, maaend.exe)
[...] Not found matched name
[...] Record check result:{"code":2003,"msg":{"code":1,"msg":{"errorCode":10100,"filePath":"c:\\windows\\explorer.exe"}}}

# name matched, but the file has no valid signature
# (this one was produced by renaming a copy of cmd.exe to games.exe)
[...] Parent process verify signature failed:31540, 2148204800
[...] Record check result:{"code":2003,"msg":{"code":1,"msg":{"errorCode":10101,"filePath":"...\\games.exe"}}}
```

`2148204800` = `0x800B0100` = `TRUST_E_NOSIGNATURE` — i.e. **Windows Authenticode
verification failed**.

### `u8sdk_pc.log` — the SDK-level call and its result

```
[u8sdkimpl.cpp] [U8SDKImpl::U8StartLaunchCheck] [line:1295] Launch check result:{"code":2003,"msg":{"code":0,...}}
```

After a failure the game also tries to start the launcher itself:

```
[...] [U8SDKImpl::TryRunLauncher] [line:1073] Try run launcher success
```

via the official deep link:
`hypergryphlauncher-<appcode>://start?ta=endfield`

`<appcode>` is the launcher's build identifier and can be read from the registry:
`HKLM\SOFTWARE\Classes\hypergryphlauncher-*\shell\open\command`
— it looks like `"...\Launcher.exe" "%1"`.

---

## 2. Error codes

| errorCode | Log keyword | Meaning |
|---|---|---|
| `0` | `Parent process check success:<pid>` | passed |
| `10100` | `Not found matched name` | parent identity mismatch (not the official launcher) |
| `10101` | `Parent process verify signature failed` | identity matched, signature check failed |

Note that the `filePath` field is the **parent image path** the check used — very handy when
debugging.

---

## 3. Approaches that were rejected

| Attempt | Result | Why |
|---|---|---|
| Passing flags to `Endfield.exe` (e.g. `--no-admin`, `-skip_uac`) | no effect | elevation comes from the EXE manifest and is decided at process creation, before arguments are parsed |
| `cmd /c start Endfield.exe` | `10100` | the parent becomes `cmd.exe`, identity mismatch |
| Copying `cmd.exe` to `games.exe` and launching from it | `10101` | the name matches, but the file isn't signed by Hypergryph |
| Patching the game so it skips the check | not used | breaks file integrity, likely trips anti-cheat, and modifies the game |

Conclusion: **the signature has to be genuine — so borrow a genuine signed process as the
parent.**

---

## 4. The approach: a suspended official launcher as temporary parent

```
CreateProcessW(Games.exe, CREATE_SUSPENDED)      -> a live process that has not executed a single instruction
CreateProcessW(Endfield.exe, STARTUPINFOEX{
     AttrList = PROC_THREAD_ATTRIBUTE_PARENT_PROCESS -> that process
})
```

- `CREATE_SUSPENDED`: the launcher's entry point never runs, so no window appears and no
  single-instance mutex is taken.
- `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`: makes the new process' parent PID point at the
  process handle we supply.
- The check reads the **parent image path and signature**; it has no idea the process is
  suspended.
- Once the log shows `Parent process check success:<our suspended PID>`, we simply
  `TerminateProcess` it and the game keeps running.

Relevant snippet (the C# embedded in `src/Start-Endfield.ps1`):

```csharp
// 1) start the parent suspended
CreateProcessW(parentExe, ..., CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, ...);

// 2) attribute list: lpValue MUST point at memory holding the handle,
//    passing the handle value itself makes the kernel dereference it as a pointer
IntPtr hValue = Marshal.AllocHGlobal(IntPtr.Size);
Marshal.WriteIntPtr(hValue, piParent.hProcess);
UpdateProcThreadAttribute(list, 0, (IntPtr)0x00020000 /* PARENT_PROCESS */,
                          hValue, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);

// 3) start the game with that attribute list
CreateProcessW(childExe, ..., EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, ...);
```

> Pitfall worth remembering: passing `hProcess` directly as `lpValue` makes the kernel
> treat the handle value as a pointer and `CreateProcessW` crashes with an access violation
> (`0xC0000005`). It must be a pointer to the handle.

### Timeline

```
Start-Endfield.ps1
   │
   ├─ CreateProcessW(Games.exe, SUSPENDED)        pid=15568   executes nothing
   ├─ CreateProcessW(Endfield.exe, parent=15568)  pid=40748
   │
   ├─ poll OneChannelLC.log ...
   │      └─ "Parent process check success:15568"   ← passed
   ├─ TerminateProcess(15568)                       ← reap the suspended process
   └─ exit 0                                        ← the game keeps running
```

On failure (e.g. an invalid signature) the script immediately kills the game process it just
started, so no "launch failed" dialog is left on screen.

---

## 5. Why not other routes

- **Injection / patching**: modifies the game process or files — far more likely to trip
  anti-cheat.
- **Hooking `WinVerifyTrust`**: also requires injection, and is an explicitly adversarial
  action.
- **Forging a signature**: impossible without Hypergryph's private key.
- This approach writes nothing into the game directory, modifies no game file and touches no
  game memory — its only influence is the parent PID at process creation.

---

## 6. When it will break

| Change | Symptom | Response |
|---|---|---|
| Launcher update / `Games.exe` moves | `10100` (identity mismatch) | the script re-detects the newest signed `Games.exe`; or pass `-ParentPath` |
| Launcher replaced/corrupted, signature invalid | `10101` | repair/reinstall the official launcher |
| Server-side `gameLaunchCheck` becomes stricter | possibly new error codes | wait for the community to re-analyse |
| Launcher executable renamed | `10100` | update the candidate list in `Get-ParentCandidates` |

The first place to look is always the tail of `OneChannelLC.log`.
