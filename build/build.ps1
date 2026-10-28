#requires -version 5.1
<#
  build/build.ps1  --  编译无窗口启动器 dist\Start-Endfield.exe

  说明：
    * 不随仓库分发任何鹰角二进制或美术资源；图标在构建时从用户本机已安装的
      鹰角启动器目录（<launcher>\<版本>\res\icons\endfield.ico）读取，
      找不到就不嵌图标（exe 仍可正常工作）。
    * 只依赖 Windows 自带的 .NET Framework 编译器 csc.exe。

  用法：
    powershell -ExecutionPolicy Bypass -File build/build.ps1
    powershell -ExecutionPolicy Bypass -File build/build.ps1 -IconPath "D:\my.ico" -Force
#>

[CmdletBinding()]
param(
    [string]$LauncherRoot,
    [string]$IconPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) { Write-Host "[*] $msg" }
function Write-Bad([string]$msg)  { Write-Host "[x] $msg" -ForegroundColor Red }

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcCs    = Join-Path $repoRoot 'src\EndfieldLauncher.cs'
$distDir  = Join-Path $repoRoot 'dist'
$outExe   = Join-Path $distDir 'Start-Endfield.exe'

if (-not (Test-Path -LiteralPath $srcCs)) { Write-Bad "找不到源码：$srcCs"; exit 1 }
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

if ((Test-Path -LiteralPath $outExe) -and -not $Force) {
    Write-Step "已存在 $outExe（加 -Force 可强制重新编译）"
    exit 0
}

# ---------------------------------------------------------------- 找 csc.exe
$csc = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $csc) {
    Write-Bad '找不到 .NET Framework 编译器 csc.exe（需要 Windows 自带的 .NET Framework 4.x）。'
    exit 1
}
Write-Step "编译器：$csc"

# ---------------------------------------------------------------- 找图标（从本机启动器里取）
function Find-LauncherRoot {
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

if (-not $IconPath) {
    if (-not $LauncherRoot) { $LauncherRoot = Find-LauncherRoot }
    if ($LauncherRoot -and (Test-Path -LiteralPath $LauncherRoot)) {
        $icons = @(Get-ChildItem -LiteralPath $LauncherRoot -Recurse -Depth 3 -Filter 'endfield.ico' -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)
        if ($icons.Count -gt 0) { $IconPath = $icons[0].FullName }
    }
    if (-not $IconPath) {
        $local = Join-Path $repoRoot 'assets\endfield.ico'   # 本地放一份（已被 .gitignore 忽略）
        if (Test-Path -LiteralPath $local) { $IconPath = $local }
    }
}

if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
    Write-Step "图标：$IconPath"
} else {
    $IconPath = $null
    Write-Step '未找到 endfield.ico，将编译不带图标的 exe（可用 -IconPath 指定）'
}

# ---------------------------------------------------------------- 编译
$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    '/r:System.Windows.Forms.dll',
    "/out:$outExe",
    $srcCs
)
if ($IconPath) { $cscArgs = @("/win32icon:$IconPath") + $cscArgs }

& $csc @cscArgs 2>&1 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outExe)) {
    Write-Bad "编译失败（csc 退出码 $LASTEXITCODE）"
    exit 1
}

$f = Get-Item -LiteralPath $outExe
Write-Host ''
Write-Step ("编译完成：{0}（{1:N0} 字节）" -f $f.FullName, $f.Length)
exit 0
