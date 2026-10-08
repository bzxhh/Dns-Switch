<#
    重新打包 DNS-Switcher.exe
    ---------------------------------------------------------------
    用法：
        .\build-exe.ps1
      改了 DNS-Switcher.ps1 顶部的 $Presets 之后，跑一次本脚本即可重新打包。

    说明：
      · 依赖 ps2exe 模块（已装到用户目录 Documents\WindowsPowerShell\Modules）
      · 本机有删除保护，覆盖式删除会被拦截，所以旧 exe 先改名挪到临时目录
      · 打包器收尾时清理临时清单文件也会触发该保护，报错可忽略 ——
        本脚本以「exe 是否生成」为准来判断成败
#>
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

$d   = $PSScriptRoot
$src = Join-Path $d 'DNS-Switcher.ps1'
$exe = Join-Path $d 'DNS-Switcher.exe'
$ico = Join-Path $env:TEMP 'dns_switcher_icon.ico'

if (-not (Test-Path -LiteralPath $src)) {
    Write-Host ("  找不到源文件：" + $src) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '  [1/4] 载入 ps2exe ...' -ForegroundColor Cyan
Import-Module ps2exe -Force

Write-Host '  [2/4] 生成图标 ...' -ForegroundColor Cyan
Add-Type -AssemblyName System.Drawing
$size = 64
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::Transparent)

$rr = 14
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(0, 0, ($rr * 2), ($rr * 2), 180, 90)
$path.AddArc(($size - $rr * 2 - 1), 0, ($rr * 2), ($rr * 2), 270, 90)
$path.AddArc(($size - $rr * 2 - 1), ($size - $rr * 2 - 1), ($rr * 2), ($rr * 2), 0, 90)
$path.AddArc(0, ($size - $rr * 2 - 1), ($rr * 2), ($rr * 2), 90, 90)
$path.CloseFigure()
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(47, 111, 235))
$g.FillPath($brush, $path)

$font = New-Object System.Drawing.Font('Segoe UI', 19, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = [System.Drawing.StringAlignment]::Center
$fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
$white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$rectF = New-Object System.Drawing.RectangleF(0, 1, $size, $size)
$g.DrawString('DNS', $font, $white, $rectF, $fmt)
$g.Dispose()

if (Test-Path -LiteralPath $ico) {
    Move-Item -LiteralPath $ico -Destination (Join-Path $env:TEMP ("old_icon_" + (Get-Date -Format 'HHmmss') + ".ico")) -Force
}
$hicon = $bmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hicon)
$fs = [System.IO.File]::Create($ico)
$icon.Save($fs)
$fs.Close()
$icon.Dispose()
$bmp.Dispose()

Write-Host '  [3/4] 挪走旧 exe ...' -ForegroundColor Cyan
if (Test-Path -LiteralPath $exe) {
    Move-Item -LiteralPath $exe -Destination (Join-Path $env:TEMP ("old_" + (Get-Date -Format 'HHmmss') + "_DNS-Switcher.exe")) -Force
}

Write-Host '  [4/4] 打包 ...' -ForegroundColor Cyan
$params = @{
    InputFile    = $src
    OutputFile   = $exe
    IconFile     = $ico
    Title        = 'DNS 快速切换'
    Description  = '网卡 DNS 一键切换工具'
    Product      = 'DNS Switcher'
    Company      = 'Z'
    Version      = '1.0.0.0'
    RequireAdmin = $true
    NoConsole    = $true
}
try { Invoke-PS2EXE @params | Out-Null } catch { }

Write-Host ''
if (Test-Path -LiteralPath $exe) {
    $kb = [int]((Get-Item -LiteralPath $exe).Length / 1KB)
    Write-Host ("  打包完成  ->  DNS-Switcher.exe  (" + $kb + " KB)") -ForegroundColor Green
    Write-Host '  双击即可运行。改预设只需改 DNS-Switcher.ps1 顶部的 $Presets，再跑一次本脚本。' -ForegroundColor DarkGray
    Write-Host ''
}
else {
    Write-Host '  打包失败：exe 未生成' -ForegroundColor Red
    Write-Host ''
    exit 1
}
