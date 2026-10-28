#requires -version 5.1
<#
  Start-Endfield.ps1  --  Launch Arknights: Endfield (game client) directly, bypassing the
  "请通过官方启动器打开游戏 / Open the game via the official launcher" gate.

  原理 / How it works
  -------------------
  游戏内的 OneChannelLC 模块在校验「父进程」：
    1) 父进程可执行文件的身份必须匹配官方启动器（否则 errorCode 10100 "Not found matched name"）；
    2) 父进程文件必须能通过 Windows Authenticode 签名校验（失败 -> errorCode 10101
       "Parent process verify signature failed"）。
  因此本脚本：
    * 以 CREATE_SUSPENDED 启动真实的、带鹰角签名的官方 Games.exe 作为「临时父进程」
      （挂起状态 -> 不创建窗口、不执行启动器逻辑）；
    * 再用 PROC_THREAD_ATTRIBUTE_PARENT_PROCESS 让 Endfield.exe 以该进程为父进程创建；
    * 看到日志出现 "Parent process check success:<PID>" 后立即结束挂起进程，游戏继续运行。

  参数 / Parameters
  -----------------
    -GameExe      游戏本体路径（默认自动探测）
    -ParentPath   作为父进程的可执行文件（默认自动选择带签名的官方启动器）
    -LauncherRoot 鹰角启动器安装根目录（默认从注册表探测）
    -GameArgs     传给游戏本体的附加参数
    -NoElevate    不自动提权（调试用）
    -KeepParent   校验通过后保留挂起父进程（调试用）
    -TimeoutSeconds 等待校验的秒数，默认 90

  用法 / Usage
  ------------
    powershell -NoProfile -ExecutionPolicy Bypass -File Start-Endfield.ps1
#>

[CmdletBinding()]
param(
    [string]$GameExe,
    [string]$ParentPath,
    [string]$LauncherRoot,
    [string]$GameArgs = '',
    [switch]$NoElevate,
    [switch]$KeepParent,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'

$script:LogFile = Join-Path $env:TEMP 'Start-Endfield.log'
$script:ConfigFile = Join-Path $PSScriptRoot 'Start-Endfield.config.json'

function Write-Log([string]$msg) {
    try {
        Add-Content -LiteralPath $script:LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) `
            -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Write-Step([string]$msg) { Write-Host "[*] $msg"; Write-Log "INFO $msg" }
function Write-Bad([string]$msg)  { Write-Host "[x] $msg" -ForegroundColor Red; Write-Log "FAIL $msg" }

trap {
    $detail = "{0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log "ERROR $detail"
    Write-Host "[x] 脚本异常：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 小工具
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-HgSignature([string]$path) {
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $path
        return ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Hypergryph|Gryphline')
    } catch { return $false }
}

function Find-LauncherRoot {
    # 注册表里的 URL 协议处理器指向启动器：.. \Launcher.exe
    foreach ($hive in @('HKLM:\SOFTWARE\Classes', 'HKCU:\Software\Classes')) {
        $keys = @(Get-ChildItem -Path $hive -ErrorAction SilentlyContinue |
                  Where-Object { $_.PSChildName -like 'hypergryphlauncher-*' })
        foreach ($k in $keys) {
            $cmd = (Get-ItemProperty -Path (Join-Path $k.PSPath 'shell\open\command') -ErrorAction SilentlyContinue).'(default)'
            if ($cmd -match '^"?([^"]+\\Launcher\.exe)"?') { return (Split-Path -Parent $matches[1]) }
        }
    }
    return $null
}

function Find-GameExe([string]$root) {
    $p = Join-Path $root 'games\Endfield Game\Endfield.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $hits = Get-ChildItem -LiteralPath (Join-Path $root 'games') -Recurse -Depth 3 `
                -Filter 'Endfield.exe' -File -ErrorAction SilentlyContinue
    if ($hits) { return $hits[0].FullName }
    return $null
}

function Get-ParentCandidates([string]$root) {
    $list = New-Object System.Collections.Generic.List[string]
    # 1) 各版本目录里的 Games.exe —— 正常启动游戏时它就是父进程
    Get-ChildItem -LiteralPath $root -Recurse -Depth 3 -Filter 'Games.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -notlike '*\games\*' } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { if (Test-HgSignature $_.FullName) { $list.Add($_.FullName) } }
    # 2) 启动器根目录的 Launcher.exe 作为后备
    $rootLauncher = Join-Path $root 'Launcher.exe'
    if ((Test-Path -LiteralPath $rootLauncher) -and (Test-HgSignature $rootLauncher)) { $list.Add($rootLauncher) }
    return ($list | Select-Object -Unique)
}

# ---------------------------------------------------------------- 读取上次成功的配置
$saved = $null
if (Test-Path -LiteralPath $script:ConfigFile) {
    try { $saved = Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
}
# 无 UAC 模式（计划任务）无法直接传参：由启动器把参数写进 Start-Endfield.args
if (-not $GameArgs) {
    $argsFile = Join-Path $PSScriptRoot 'Start-Endfield.args'
    if (Test-Path -LiteralPath $argsFile) {
        try { $GameArgs = (Get-Content -LiteralPath $argsFile -Raw -ErrorAction Stop).Trim() } catch { }
    }
}
if (-not $LauncherRoot -and $saved.LauncherRoot -and (Test-Path -LiteralPath (Join-Path $saved.LauncherRoot 'Launcher.exe'))) {
    $LauncherRoot = $saved.LauncherRoot
}
if (-not $GameExe -and $saved.GameExe -and (Test-Path -LiteralPath $saved.GameExe)) { $GameExe = $saved.GameExe }
if (-not $ParentPath -and $saved.ParentPath -and (Test-Path -LiteralPath $saved.ParentPath) -and (Test-HgSignature $saved.ParentPath)) {
    $ParentPath = $saved.ParentPath
}

# ---------------------------------------------------------------- 定位路径
if (-not $LauncherRoot) { $LauncherRoot = Find-LauncherRoot }
if (-not $LauncherRoot) {
    throw "未找到鹰角启动器安装目录。请用 -LauncherRoot 指定，例如：-LauncherRoot 'D:\Hypergryph Launcher'"
}
if (-not (Test-Path -LiteralPath $LauncherRoot)) { throw "启动器目录不存在: $LauncherRoot" }

if (-not $GameExe) {
    $GameExe = Find-GameExe $LauncherRoot
    if (-not $GameExe) { throw "在 ${LauncherRoot}\games 下未找到 Endfield.exe，请用 -GameExe 指定。" }
}
if (-not (Test-Path -LiteralPath $GameExe)) { throw "游戏路径不存在: $GameExe" }

$gameDir  = Split-Path -Parent $GameExe
$gameName = [IO.Path]::GetFileNameWithoutExtension($GameExe)

$candidates = if ($ParentPath) { @($ParentPath) } else { @(Get-ParentCandidates $LauncherRoot) }
if (-not $candidates -or $candidates.Count -eq 0) {
    throw "在 $LauncherRoot 下没有找到带鹰角签名的启动器可执行文件，请用 -ParentPath 指定。"
}

# 游戏已在运行则直接退出
$running = Get-Process -Name $gameName -ErrorAction SilentlyContinue
if ($running) { Write-Step "游戏已在运行 (PID: $($running.Id -join ', '))，无需重复启动。"; exit 0 }

# ---------------------------------------------------------------- 提权
# Endfield.exe 与官方 Games.exe 的清单都要求管理员权限（requireAdministrator），
# 所以整个启动流程必须在管理员上下文中进行（与官方启动器行为一致）。
if (-not (Test-Admin) -and -not $NoElevate) {
    Write-Step '需要管理员权限，正在请求 UAC 提权…'
    # 注意：Start-Process 的 -ArgumentList 不会自动为带空格的路径加引号，这里手动加
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($GameExe)     { $argList += @('-GameExe', ('"{0}"' -f $GameExe)) }
    if ($LauncherRoot) { $argList += @('-LauncherRoot', ('"{0}"' -f $LauncherRoot)) }
    if ($GameArgs)    { $argList += @('-GameArgs', ('"{0}"' -f ($GameArgs -replace '"', '\"'))) }
    if ($TimeoutSeconds) { $argList += @('-TimeoutSeconds', $TimeoutSeconds) }
    if ($KeepParent)  { $argList += '-KeepParent' }
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -PassThru
    } catch {
        Write-Bad "提权被拒绝：$($_.Exception.Message)"
        exit 1
    }
    $proc.WaitForExit()
    exit $proc.ExitCode
}

# ---------------------------------------------------------------- 日志目录（随渠道不同）
$company = 'Hypergryph'
$appInfo = Join-Path $gameDir 'Endfield_Data\app.info'
if (Test-Path -LiteralPath $appInfo) {
    $line = Get-Content -LiteralPath $appInfo -TotalCount 1 -ErrorAction SilentlyContinue
    if ($line) { $company = $line.Trim() }
}
$lcLog = Join-Path $env:USERPROFILE "AppData\LocalLow\$company\Endfield\sdklogs\OneChannelLC.log"

# ---------------------------------------------------------------- 原生调用
if (-not ('ParentSpoofLauncher' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class ParentSpoofLauncher
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public IntPtr lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
        IntPtr lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute,
        IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    static readonly IntPtr PT_ATTRIBUTE_PARENT_PROCESS = (IntPtr)0x00020000;

    static IntPtr AllocStartupInfo(IntPtr attrList)
    {
        int size = Marshal.SizeOf(typeof(STARTUPINFOEX));
        IntPtr p = Marshal.AllocHGlobal(size);
        for (int i = 0; i < size; i++) Marshal.WriteByte(p, i, 0);
        int cb = (attrList == IntPtr.Zero) ? Marshal.SizeOf(typeof(STARTUPINFO)) : size;
        Marshal.WriteInt32(p, 0, cb);
        if (attrList != IntPtr.Zero)
        {
            int off = (int)(long)Marshal.OffsetOf(typeof(STARTUPINFOEX), "lpAttributeList");
            Marshal.WriteIntPtr(p, off, attrList);
        }
        return p;
    }

    /// <summary>
    /// 以 parentExe（挂起状态）作为 childExe 的父进程启动 childExe。
    /// 返回 int[2] = { 父PID, 子PID }。失败时抛出 Win32Exception（含 NativeErrorCode）。
    /// </summary>
    public static int[] Start(string parentExe, string childExe, string childArgs, string childWorkDir)
    {
        PROCESS_INFORMATION piParent = new PROCESS_INFORMATION();
        PROCESS_INFORMATION piChild = new PROCESS_INFORMATION();
        IntPtr siParent = IntPtr.Zero, siChild = IntPtr.Zero, list = IntPtr.Zero;

        try
        {
            // 1) 挂起启动“临时父进程”
            siParent = AllocStartupInfo(IntPtr.Zero);
            var cmdParent = new StringBuilder("\"" + parentExe + "\"");
            if (!CreateProcessW(parentExe, cmdParent, IntPtr.Zero, IntPtr.Zero, false,
                    CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero,
                    System.IO.Path.GetDirectoryName(parentExe), siParent, out piParent))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "创建挂起的父进程失败");
            }

            // 2) 属性列表：指定父进程句柄
            //    注意：lpValue 必须指向“保存句柄的内存”，直接传句柄值会被内核当指针解引用
            IntPtr attrSize = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
            list = Marshal.AllocHGlobal(attrSize);
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref attrSize))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "InitializeProcThreadAttributeList 失败");
            IntPtr hValue = Marshal.AllocHGlobal(IntPtr.Size);
            try
            {
                Marshal.WriteIntPtr(hValue, piParent.hProcess);
                if (!UpdateProcThreadAttribute(list, 0, PT_ATTRIBUTE_PARENT_PROCESS,
                        hValue, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateProcThreadAttribute 失败");
            }
            finally { Marshal.FreeHGlobal(hValue); }

            // 3) 启动游戏本体
            siChild = AllocStartupInfo(list);
            var cmdChild = new StringBuilder("\"" + childExe + "\"");
            if (!string.IsNullOrEmpty(childArgs)) cmdChild.Append(' ').Append(childArgs);

            if (!CreateProcessW(childExe, cmdChild, IntPtr.Zero, IntPtr.Zero, false,
                    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero,
                    childWorkDir, siChild, out piChild))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "启动游戏本体失败");
            }
        }
        catch
        {
            // 子进程没起来时，别把挂起的父进程留在后台
            if (piParent.dwProcessId != 0)
            {
                try { System.Diagnostics.Process.GetProcessById(piParent.dwProcessId).Kill(); } catch { }
            }
            throw;
        }
        finally
        {
            if (siParent != IntPtr.Zero) Marshal.FreeHGlobal(siParent);
            if (siChild != IntPtr.Zero) Marshal.FreeHGlobal(siChild);
            if (list != IntPtr.Zero) { DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); }
            if (piParent.hThread != IntPtr.Zero) CloseHandle(piParent.hThread);
            if (piParent.hProcess != IntPtr.Zero) CloseHandle(piParent.hProcess);
            if (piChild.hThread != IntPtr.Zero) CloseHandle(piChild.hThread);
            if (piChild.hProcess != IntPtr.Zero) CloseHandle(piChild.hProcess);
        }

        return new int[] { piParent.dwProcessId, piChild.dwProcessId };
    }
}
'@
}

# ---------------------------------------------------------------- 单次尝试
function Read-NewLog([string]$path, [long]$offset) {
    if (-not (Test-Path -LiteralPath $path)) { return @{ Text = ''; Offset = $offset } }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $len = $fs.Length
        if ($len -le $offset) { return @{ Text = ''; Offset = $offset } }
        [void]$fs.Seek($offset, 'Begin')
        $buf = New-Object byte[] ($len - $offset)
        [void]$fs.Read($buf, 0, $buf.Length)
        return @{ Text = [Text.Encoding]::GetEncoding(936).GetString($buf); Offset = $len }
    } finally { $fs.Dispose() }
}

function Invoke-Attempt {
    param([string]$ParentExe)

    $offset = 0L
    if (Test-Path -LiteralPath $lcLog) { $offset = (Get-Item -LiteralPath $lcLog).Length }

    Write-Step "临时父进程: $ParentExe  (挂起，不显示界面)"
    if ($GameArgs) { Write-Step "游戏附加参数: $GameArgs" }
    $ids = [ParentSpoofLauncher]::Start($ParentExe, $GameExe, $GameArgs, $gameDir)
    $parentPid = $ids[0]; $childPid = $ids[1]
    Write-Step "已启动游戏 PID=$childPid（临时父进程 PID=$parentPid），等待启动校验…"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $success = $false
    $failLine = $null
    $childDied = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        $r = Read-NewLog $lcLog $offset
        if ($r.Text) {
            $offset = $r.Offset
            foreach ($ln in ($r.Text -split "`r?`n")) {
                if ($ln -match 'Parent process check success:(\d+)' -and [int]$matches[1] -eq $parentPid) { $success = $true }
                if ($ln -match 'Record check result:.*"code":1') { $failLine = $ln.Trim() }
            }
        }
        if ($success -or $failLine) { break }
        if (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) { $childDied = $true; break }
    }

    if ($success) {
        if (-not $KeepParent) { Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $true; Parent = $ParentExe; ChildPid = $childPid }
    }

    # 失败：清理本次启动
    Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue
    $msg = if ($failLine) { $failLine } elseif ($childDied) { '游戏进程在校验阶段退出' } else { "等待校验超时(${TimeoutSeconds}s)" }
    return @{ Ok = $false; Parent = $ParentExe; Error = $msg }
}

# ---------------------------------------------------------------- 主流程
$results = @()
foreach ($cand in $candidates) {
    try {
        $r = Invoke-Attempt $cand
    } catch {
        $ex = $_.Exception
        $code = 0
        if ($ex -is [ComponentModel.Win32Exception]) { $code = $ex.NativeErrorCode }
        elseif ($ex.InnerException -is [ComponentModel.Win32Exception]) { $code = $ex.InnerException.NativeErrorCode }

        if ($code -eq 740 -or $code -eq 5) {
            if (-not (Test-Admin) -and -not $NoElevate) {
                Write-Step "父进程需要管理员权限，正在请求提权…"
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                             '-GameExe', ('"{0}"' -f $GameExe), '-ParentPath', ('"{0}"' -f $cand),
                             '-LauncherRoot', ('"{0}"' -f $LauncherRoot), '-TimeoutSeconds', $TimeoutSeconds)
                if ($GameArgs) { $argList += @('-GameArgs', ('"{0}"' -f ($GameArgs -replace '"', '\"'))) }
                if ($KeepParent) { $argList += '-KeepParent' }
                try {
                    $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -PassThru
                    $proc.WaitForExit()
                    exit $proc.ExitCode
                } catch {
                    Write-Bad "提权被拒绝：$($_.Exception.Message)"
                    exit 1
                }
            }
            $results += [pscustomobject]@{ Parent = $cand; Error = "需要管理员权限(错误码 $code)；请以管理员身份运行" }
            continue
        }
        $inner = $ex.InnerException
        $detail = if ($inner -and $inner.Message) { $inner.Message } else { $ex.Message }
        $results += [pscustomobject]@{ Parent = $cand; Error = "$detail (code=$code)" }
        continue
    }

    if ($r.Ok) {
        try {
            @{ LauncherRoot = $LauncherRoot; GameExe = $GameExe; ParentPath = $r.Parent } |
                ConvertTo-Json | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
        } catch { }
        Write-Step '启动校验已通过（Parent process check success），游戏正常启动。'
        exit 0
    }
    $results += [pscustomobject]@{ Parent = $r.Parent; Error = $r.Error }
}

Write-Host ''
Write-Host '以下父进程候选均未通过启动校验：' -ForegroundColor Yellow
foreach ($x in $results) { Write-Host ("  - {0}`n      {1}" -f $x.Parent, $x.Error) -ForegroundColor Yellow }
Write-Bad '启动失败。请查看 docs/troubleshooting.md，或用 -ParentPath 指定带鹰角签名的可执行文件。'
exit 1
