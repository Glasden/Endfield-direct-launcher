#requires -version 5.1
<#
  install.ps1  --  安装 / 卸载 Endfield direct launcher

  安装内容：
    %LOCALAPPDATA%\Programs\EndfieldDirect\
        Start-Endfield.exe   无窗口启动器（构建产物）
        Start-Endfield.ps1   实际启动逻辑
    桌面快捷方式「终末地」
    可选：计划任务 EndfieldDirectLaunch（-Mode Task，最高权限、免 UAC）

  两种模式：
    -Mode Uac   默认。启动时请求一次 UAC（与官方启动器行为一致），最保守。
    -Mode Task  注册最高权限计划任务，之后启动完全无 UAC。
                ⚠ 这会让“任何能执行该任务的程序”获得管理员权限，请自行权衡。

  用法：
    安装（默认 UAC 模式）：  powershell -ExecutionPolicy Bypass -File install.ps1
    安装（免 UAC 模式）：    powershell -ExecutionPolicy Bypass -File install.ps1 -Mode Task
    卸载：                  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet('Uac', 'Task')]
    [string]$Mode = 'Uac',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\EndfieldDirect'),
    [string]$LauncherRoot,
    [string]$TaskName = 'EndfieldDirectLaunch',
    [string]$ShortcutName = '终末地',
    [switch]$Uninstall,
    [switch]$NoElevate,
    [switch]$NoShortcut,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) { Write-Host "[*] $msg" }
function Write-Bad([string]$msg)  { Write-Host "[x] $msg" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$repoRoot = $PSScriptRoot
$srcDir   = Join-Path $repoRoot 'src'
$distExe  = Join-Path $repoRoot 'dist\Start-Endfield.exe'
$desktop  = [Environment]::GetFolderPath('Desktop')
$desktopLnk = Join-Path $desktop ($ShortcutName + '.lnk')

# ---------------------------------------------------------------- 提权（注册计划任务需要管理员）
if (-not (Test-Admin) -and -not $NoElevate -and -not $Uninstall -and $Mode -eq 'Task') {
    Write-Step '注册计划任务需要管理员权限，正在请求提权…'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                 '-Mode', $Mode,
                 '-InstallDir', ('"{0}"' -f $InstallDir),
                 '-TaskName', ('"{0}"' -f $TaskName),
                 '-ShortcutName', ('"{0}"' -f $ShortcutName))
    if ($LauncherRoot) { $argList += @('-LauncherRoot', ('"{0}"' -f $LauncherRoot)) }
    $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -PassThru
    $proc.WaitForExit()
    exit $proc.ExitCode
}

# ---------------------------------------------------------------- 卸载
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Step "已删除计划任务：$TaskName"
    }
    if (Test-Path -LiteralPath $desktopLnk) {
        Remove-Item -LiteralPath $desktopLnk -Force
        Write-Step "已删除桌面快捷方式：$desktopLnk"
    }
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Step "已删除安装目录：$InstallDir"
    }
    Write-Step '卸载完成。'
    exit 0
}

# ---------------------------------------------------------------- 构建
if (-not (Test-Path -LiteralPath $distExe)) {
    if ($SkipBuild) { Write-Bad "缺少 $distExe，且指定了 -SkipBuild。"; exit 1 }
    Write-Step '首次安装，正在构建启动器…'
    $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $repoRoot 'build\build.ps1')))
    if ($LauncherRoot) { $buildArgs += @('-LauncherRoot', ('"{0}"' -f $LauncherRoot)) }
    $bp = Start-Process -FilePath 'powershell.exe' -ArgumentList $buildArgs -Wait -PassThru
    if ($bp.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $distExe)) {
        Write-Bad '构建失败，请先手动运行 build\build.ps1 查看错误。'
        exit 1
    }
}

# ---------------------------------------------------------------- 复制文件
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
# 升级安装前清理旧文件，避免旧版本脚本/参数残留
Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $srcDir 'Start-Endfield.ps1') -Destination (Join-Path $InstallDir 'Start-Endfield.ps1') -Force
Copy-Item -LiteralPath $distExe -Destination (Join-Path $InstallDir 'Start-Endfield.exe') -Force
Write-Step "已安装文件到：$InstallDir"

# ---------------------------------------------------------------- 计划任务（免 UAC 模式）
if ($Mode -eq 'Task') {
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $InstallDir 'Start-Endfield.ps1'))
        $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
            -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings `
            -Description 'Endfield direct launcher (bypass launcher check)' -Force | Out-Null
        Write-Step "已注册计划任务：$TaskName（最高权限，仅登录时，无触发器）"
    } catch {
        Write-Bad "注册计划任务失败：$($_.Exception.Message)"
        exit 1
    }
} else {
    # UAC 模式：确保不残留旧任务，走“每次启动请求一次 UAC”的路径
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Step "已移除旧的计划任务：$TaskName（当前为 UAC 模式）"
    }
}

# ---------------------------------------------------------------- 桌面快捷方式
if (-not $NoShortcut) {
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($desktopLnk)
        $lnk.TargetPath = Join-Path $InstallDir 'Start-Endfield.exe'
        $lnk.WorkingDirectory = $InstallDir
        $lnk.IconLocation = (Join-Path $InstallDir 'Start-Endfield.exe') + ',0'
        $lnk.Description = '直接启动《明日方舟：终末地》（非官方，免启动器）'
        $lnk.WindowStyle = 1
        $lnk.Save()
        Write-Step "已创建桌面快捷方式：$desktopLnk"
    } catch {
        Write-Bad "创建桌面快捷方式失败：$($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host ('安装完成（模式：{0}）' -f $Mode) -ForegroundColor Green
if ($Mode -eq 'Task') {
    Write-Host '  双击桌面快捷方式即可启动，全程无 UAC。'
} else {
    Write-Host '  双击桌面快捷方式启动，会请求一次 UAC（与官方启动器一致）。'
    Write-Host '  想免 UAC：re-run install.ps1 -Mode Task'
}
exit 0
