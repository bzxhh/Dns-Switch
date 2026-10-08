<#
    DNS 快速切换  ——  网卡 DNS 一键切换工具
    ---------------------------------------------------------------
    用法：
      · 双击 DNS-Switcher.bat（或右键本文件「使用 PowerShell 运行」）→ 打开图形界面
      · 命令行：
          .\DNS-Switcher.ps1 -List                     列出网卡与当前 DNS
          .\DNS-Switcher.ps1 -Adapter 有线网 -Preset 阿里
          .\DNS-Switcher.ps1 -Adapter 有线网 -DNS 1.1.1.1,1.0.0.1
          .\DNS-Switcher.ps1 -Adapter 有线网 -Auto      恢复自动获取
    说明：
      · 修改 DNS 需要管理员权限；图形界面会自动申请提权（弹 UAC）
      · 只处理 IPv4 DNS；切换后自动刷新 DNS 缓存
      · 想加自己的预设，改下面 $Presets 那段即可
#>
[CmdletBinding()]
param(
    [string]   $Adapter,      # 网卡名称（支持模糊匹配）
    [string]   $Preset,       # 预设名称（支持模糊匹配）
    [string[]] $DNS,          # 自定义 DNS，如 -DNS 1.1.1.1,1.0.0.1
    [switch]   $Auto,         # 恢复自动获取
    [switch]   $List,         # 列出网卡
    [switch]   $AllAdapters,  # 连同虚拟网卡一起显示
    [switch]   $SelfTest      # 开发自检：只构建界面不显示。正常使用无需此参数
)

$ErrorActionPreference = 'Stop'

# ================================================================
#  预设 DNS —— 加一行就是加一个卡片
#  格式：'显示名称' = @('主DNS','备DNS')
#  空数组 @() 表示「自动获取（DHCP）」
# ================================================================
$Presets = [ordered]@{
    '自动获取'   = @()
    '阿里 DNS'   = @('223.5.5.5', '223.6.6.6')
    '腾讯 DNS'   = @('119.29.29.29', '182.254.116.116')
    '114 DNS'    = @('114.114.114.114', '114.114.115.115')
    '百度 DNS'   = @('180.76.76.76')
    'DNSPod'     = @('119.29.29.29', '1.12.12.12')
    'Cloudflare' = @('1.1.1.1', '1.0.0.1')
    'Google'     = @('8.8.8.8', '8.8.4.4')
    'Quad9'      = @('9.9.9.9', '149.112.112.112')
    'OpenDNS'    = @('208.67.222.222', '208.67.220.220')
	'预设1'    = @('192.168.8.152', '8.8.8.8')
	'预设2'    = @('192.168.8.61', '8.8.8.8')
	'预设3'    = @('192.168.8.66', '8.8.8.8')
}

# 虚拟网卡特征词 —— 命中即视为虚拟网卡，默认隐藏
$VirtualKeywords = @(
    'Hyper-V', 'Virtual', 'VMware', 'VirtualBox', 'Tailscale', 'VPN',
    'TAP-', 'TUN', 'Loopback', 'Bluetooth', 'Npcap', 'Wintun', 'Miniport',
    'Sangfor', 'ZeroTier', 'Radmin', 'Hamachi', 'Docker', 'vEthernet', 'Tunnel'
)

# ================================================================
#  基础函数
# ================================================================
function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AdapterList {
    param([switch]$IncludeVirtual)

    $all = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' })

    if (-not $IncludeVirtual) {
        $all = @($all | Where-Object {
            $desc = $_.InterfaceDescription
            $hit = $false
            foreach ($kw in $VirtualKeywords) {
                if ($desc -like "*$kw*") { $hit = $true; break }
            }
            -not $hit
        })
    }

    return @($all | Sort-Object `
        @{ Expression = { switch ($_.Status) { 'Up' { 0 } 'Disconnected' { 1 } default { 2 } } } }, `
        Name)
}

function Get-AdapterDns {
    param([int]$IfIndex)
    $r = Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($r -and $r.ServerAddresses) { return @($r.ServerAddresses) }
    return @()
}

function Set-AdapterDns {
    param([int]$IfIndex, [string[]]$Servers)

    try {
        if (-not $Servers -or @($Servers).Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ResetServerAddresses -ErrorAction Stop
        }
        else {
            Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses $Servers -ErrorAction Stop
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        return @{ Ok = $true; Msg = '' }
    }
    catch {
        return @{ Ok = $false; Msg = $_.Exception.Message }
    }
}

function Get-PingMs {
    param([string]$Server)
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($Server, 1000)
        if ($reply.Status -eq 'Success') { return [int]$reply.RoundtripTime }
    }
    catch { }
    return -1
}

function Get-DnsLatency {
    param([string]$Server)
    $vals = @()
    for ($i = 0; $i -lt 2; $i++) {
        $v = Get-PingMs -Server $Server
        if ($v -ge 0) { $vals += $v }
    }
    if ($vals.Count -gt 0) { return [int](($vals | Measure-Object -Average).Average) }
    return -1
}

function Format-Col {
    # 按「显示宽度」补齐：中文/全角算 2 格，其余算 1 格
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -gt 127) { $w += 2 } else { $w += 1 }
    }
    $pad = $Width - $w
    if ($pad -lt 1) { $pad = 1 }
    return $Text + (' ' * $pad)
}

function Resolve-PresetKey {
    param([string]$Name)
    $keys = @($Presets.Keys)
    $exact = @($keys | Where-Object { $_ -eq $Name })
    if ($exact.Count -gt 0) { return $exact[0] }
    $fuzzy = @($keys | Where-Object { $_ -like "*$Name*" })
    if ($fuzzy.Count -gt 0) { return $fuzzy[0] }
    return $null
}

$CliMode = $List -or $Adapter -or $Preset -or $DNS -or $Auto

# ================================================================
#  命令行模式
# ================================================================
if ($CliMode) {

    if ($List -or (-not $Adapter -and -not $Preset -and -not $DNS -and -not $Auto)) {
        $rows = Get-AdapterList -IncludeVirtual:$AllAdapters
        if ($rows.Count -eq 0) {
            Write-Host '没有找到可用网卡。加 -AllAdapters 试试。' -ForegroundColor Yellow
            return
        }
        Write-Host ''
        Write-Host ('  ' + (Format-Col 'IDX' 5) + (Format-Col '网卡' 30) + (Format-Col '状态' 10) + 'DNS') -ForegroundColor Cyan
        Write-Host ('  ' + ('-' * 74)) -ForegroundColor DarkGray
        foreach ($a in $rows) {
            $dns = Get-AdapterDns -IfIndex $a.ifIndex
            $dnsText = if ($dns.Count -gt 0) { ($dns -join ', ') } else { '自动获取 (DHCP)' }
            $stateText = switch ($a.Status) { 'Up' { '已连接' } 'Disconnected' { '未连接' } default { $a.Status } }
            $color = if ($a.Status -eq 'Up') { 'White' } else { 'DarkGray' }
            $line = '  ' + (Format-Col ([string]$a.ifIndex) 5) + (Format-Col $a.Name 30) + (Format-Col $stateText 10) + $dnsText
            Write-Host $line -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '  切换示例：.\DNS-Switcher.ps1 -Adapter 有线网 -Preset 阿里' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    if (-not (Test-Admin)) {
        Write-Host ''
        Write-Host '  ✗ 修改 DNS 需要管理员权限。' -ForegroundColor Red
        Write-Host '    请用「以管理员身份运行」打开 PowerShell 后重试。' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }

    $target = $null
    if ($Adapter) {
        $cands = @(Get-AdapterList -IncludeVirtual:$AllAdapters | Where-Object { $_.Name -eq $Adapter })
        if ($cands.Count -eq 0) {
            $cands = @(Get-AdapterList -IncludeVirtual:$AllAdapters | Where-Object { $_.Name -like "*$Adapter*" })
        }
        if ($cands.Count -eq 0) {
            Write-Host "  ✗ 找不到网卡：$Adapter（用 -List 查看）" -ForegroundColor Red
            exit 1
        }
        if ($cands.Count -gt 1) {
            Write-Host "  ! 「$Adapter」匹配到多个网卡，使用第一个：$($cands[0].Name)" -ForegroundColor Yellow
        }
        $target = $cands[0]
    }
    else {
        $up = @(Get-AdapterList -IncludeVirtual:$AllAdapters | Where-Object { $_.Status -eq 'Up' })
        if ($up.Count -eq 0) { Write-Host '  ✗ 没有已连接的网卡。' -ForegroundColor Red; exit 1 }
        $target = $up[0]
        Write-Host "  · 未指定网卡，使用：$($target.Name)" -ForegroundColor DarkGray
    }

    $servers = $null
    $label = ''
    if ($Auto) {
        $servers = @()
        $label = '自动获取 (DHCP)'
    }
    elseif ($DNS) {
        $servers = @($DNS)
        $label = ($servers -join ', ')
    }
    elseif ($Preset) {
        $key = Resolve-PresetKey -Name $Preset
        if (-not $key) {
            Write-Host "  ✗ 找不到预设：$Preset" -ForegroundColor Red
            Write-Host "    可用预设：$(($Presets.Keys) -join ' / ')" -ForegroundColor DarkGray
            exit 1
        }
        $servers = @($Presets[$key])
        $label = $key
    }
    else {
        Write-Host '  ✗ 请指定 -Preset / -DNS / -Auto 之一' -ForegroundColor Red
        exit 1
    }

    $result = Set-AdapterDns -IfIndex $target.ifIndex -Servers $servers
    if ($result.Ok) {
        Write-Host ''
        Write-Host "  ✓ $($target.Name)  →  $label" -ForegroundColor Green
        if ($servers.Count -gt 0) { Write-Host "    $($servers -join '   ')" -ForegroundColor DarkGray }
        Write-Host ''
    }
    else {
        Write-Host "  ✗ 切换失败：$($result.Msg)" -ForegroundColor Red
        exit 1
    }
    return
}

# ================================================================
#  图形界面模式
# ================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:IsAdmin = Test-Admin

if (-not $script:IsAdmin -and -not $SelfTest) {
    try {
        $psExe = Join-Path $PSHOME 'powershell.exe'
        Start-Process -FilePath $psExe -Verb RunAs -ErrorAction Stop -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
        )
        exit 0
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            '修改 DNS 需要管理员权限，但提权被取消或失败。' + [Environment]::NewLine + [Environment]::NewLine +
            '请右键 DNS-Switcher.bat →「以管理员身份运行」。',
            'DNS 快速切换', 'OK', 'Warning') | Out-Null
        exit 1
    }
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------- 配色（浅色） ----------
$C_Bg       = [Drawing.Color]::FromArgb(245, 246, 248)
$C_Card     = [Drawing.Color]::White
$C_Border   = [Drawing.Color]::FromArgb(214, 221, 230)
$C_Text     = [Drawing.Color]::FromArgb(31, 35, 40)
$C_Sub      = [Drawing.Color]::FromArgb(110, 118, 129)
$C_Accent   = [Drawing.Color]::FromArgb(47, 111, 235)
$C_AccentBg = [Drawing.Color]::FromArgb(232, 240, 254)
$C_Ok       = [Drawing.Color]::FromArgb(26, 127, 55)
$C_Warn     = [Drawing.Color]::FromArgb(154, 103, 0)
$C_Err      = [Drawing.Color]::FromArgb(207, 34, 46)

$F_Base  = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$F_Title = New-Object Drawing.Font('Microsoft YaHei UI', 14, [Drawing.FontStyle]::Bold)
$F_Bold  = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
$F_Small = New-Object Drawing.Font('Microsoft YaHei UI', 8)
$F_Tiny  = New-Object Drawing.Font('Microsoft YaHei UI', 7)

# ---------- 主窗体 ----------
$form = New-Object Windows.Forms.Form
$form.Text            = 'DNS 快速切换'
$form.ClientSize      = New-Object Drawing.Size(860, 690)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $C_Bg
$form.Font            = $F_Base

function New-FlatButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 86, [int]$H = 28)
    $b = New-Object Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object Drawing.Point($X, $Y)
    $b.Size      = New-Object Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.BackColor = $C_Card
    $b.ForeColor = $C_Text
    $b.FlatAppearance.BorderColor = $C_Border
    $b.Cursor    = 'Hand'
    return $b
}

# ---- 顶栏 ----
$header = New-Object Windows.Forms.Panel
$header.Location  = New-Object Drawing.Point(0, 0)
$header.Size      = New-Object Drawing.Size(860, 58)
$header.BackColor = $C_Card
$form.Controls.Add($header)

$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text      = 'DNS 快速切换'
$lblTitle.Font      = $F_Title
$lblTitle.ForeColor = $C_Text
$lblTitle.Location  = New-Object Drawing.Point(22, 15)
$lblTitle.AutoSize  = $true
$header.Controls.Add($lblTitle)

$lblAdmin = New-Object Windows.Forms.Label
$lblAdmin.Text      = '管理员'
$lblAdmin.Font      = $F_Small
$lblAdmin.ForeColor = $C_Ok
$lblAdmin.Location  = New-Object Drawing.Point(158, 24)
$lblAdmin.AutoSize  = $true
$header.Controls.Add($lblAdmin)

$btnTest    = New-FlatButton -Text '测速' -X 660 -Y 15 -W 80
$btnRefresh = New-FlatButton -Text '刷新' -X 748 -Y 15 -W 90
$header.Controls.Add($btnTest)
$header.Controls.Add($btnRefresh)

$headerLine = New-Object Windows.Forms.Panel
$headerLine.Location  = New-Object Drawing.Point(0, 57)
$headerLine.Size      = New-Object Drawing.Size(860, 1)
$headerLine.BackColor = $C_Border
$header.Controls.Add($headerLine)

# ---- 左侧：网卡列表 ----
$lblAdapterTitle = New-Object Windows.Forms.Label
$lblAdapterTitle.Text      = '网卡'
$lblAdapterTitle.Font      = $F_Bold
$lblAdapterTitle.ForeColor = $C_Text
$lblAdapterTitle.Location  = New-Object Drawing.Point(22, 76)
$lblAdapterTitle.AutoSize  = $true
$form.Controls.Add($lblAdapterTitle)

$listAdapters = New-Object Windows.Forms.ListBox
$listAdapters.Location       = New-Object Drawing.Point(22, 100)
$listAdapters.Size           = New-Object Drawing.Size(250, 448)
$listAdapters.BorderStyle    = 'FixedSingle'
$listAdapters.BackColor      = $C_Card
$listAdapters.ForeColor      = $C_Text
$listAdapters.IntegralHeight = $false
$listAdapters.ItemHeight     = 26
$form.Controls.Add($listAdapters)

$chkVirtual = New-Object Windows.Forms.CheckBox
$chkVirtual.Text     = '显示虚拟网卡'
$chkVirtual.Location = New-Object Drawing.Point(22, 558)
$chkVirtual.AutoSize = $true
$chkVirtual.ForeColor = $C_Sub
$form.Controls.Add($chkVirtual)

# ---- 右侧：预设卡片 ----
$lblPresetTitle = New-Object Windows.Forms.Label
$lblPresetTitle.Text      = '选择 DNS（点卡片立即切换）'
$lblPresetTitle.Font      = $F_Bold
$lblPresetTitle.ForeColor = $C_Text
$lblPresetTitle.Location  = New-Object Drawing.Point(296, 76)
$lblPresetTitle.AutoSize  = $true
$form.Controls.Add($lblPresetTitle)

$flow = New-Object Windows.Forms.FlowLayoutPanel
$flow.Location    = New-Object Drawing.Point(296, 100)
$flow.Size        = New-Object Drawing.Size(542, 380)
$flow.BackColor   = $C_Bg
$flow.AutoScroll  = $true
$flow.WrapContents = $true
$form.Controls.Add($flow)

$lblCurTitle = New-Object Windows.Forms.Label
$lblCurTitle.Text      = '当前 DNS'
$lblCurTitle.Font      = $F_Bold
$lblCurTitle.ForeColor = $C_Text
$lblCurTitle.Location  = New-Object Drawing.Point(296, 492)
$lblCurTitle.AutoSize  = $true
$form.Controls.Add($lblCurTitle)

$lblCurrent = New-Object Windows.Forms.Label
$lblCurrent.Text      = '—'
$lblCurrent.ForeColor = $C_Sub
$lblCurrent.Location  = New-Object Drawing.Point(296, 514)
$lblCurrent.Size      = New-Object Drawing.Size(542, 42)
$lblCurrent.AutoSize  = $false
$form.Controls.Add($lblCurrent)

$sep = New-Object Windows.Forms.Panel
$sep.Location  = New-Object Drawing.Point(296, 568)
$sep.Size      = New-Object Drawing.Size(542, 1)
$sep.BackColor = $C_Border
$form.Controls.Add($sep)

$lblCustom = New-Object Windows.Forms.Label
$lblCustom.Text      = '自定义 DNS'
$lblCustom.Font      = $F_Bold
$lblCustom.ForeColor = $C_Text
$lblCustom.Location  = New-Object Drawing.Point(296, 576)
$lblCustom.AutoSize  = $true
$form.Controls.Add($lblCustom)

$txtDns1 = New-Object Windows.Forms.TextBox
$txtDns1.Location    = New-Object Drawing.Point(296, 600)
$txtDns1.Size        = New-Object Drawing.Size(172, 27)
$txtDns1.BorderStyle = 'FixedSingle'
$form.Controls.Add($txtDns1)

$txtDns2 = New-Object Windows.Forms.TextBox
$txtDns2.Location    = New-Object Drawing.Point(476, 600)
$txtDns2.Size        = New-Object Drawing.Size(172, 27)
$txtDns2.BorderStyle = 'FixedSingle'
$form.Controls.Add($txtDns2)

$btnApply = New-FlatButton -Text '应用' -X 658 -Y 599 -W 86 -H 29
$btnApply.BackColor = $C_Accent
$btnApply.ForeColor = [Drawing.Color]::White
$btnApply.FlatAppearance.BorderColor = $C_Accent
$form.Controls.Add($btnApply)

$btnFlush = New-FlatButton -Text '刷新缓存' -X 752 -Y 599 -W 86 -H 29
$form.Controls.Add($btnFlush)

# ---- 底部状态栏 ----
$statusBar = New-Object Windows.Forms.Panel
$statusBar.Location  = New-Object Drawing.Point(0, 646)
$statusBar.Size      = New-Object Drawing.Size(860, 44)
$statusBar.BackColor = $C_Card
$form.Controls.Add($statusBar)

$statusLine = New-Object Windows.Forms.Panel
$statusLine.Location  = New-Object Drawing.Point(0, 0)
$statusLine.Size      = New-Object Drawing.Size(860, 1)
$statusLine.BackColor = $C_Border
$statusBar.Controls.Add($statusLine)

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Text      = '就绪'
$lblStatus.ForeColor = $C_Sub
$lblStatus.Location  = New-Object Drawing.Point(22, 13)
$lblStatus.AutoSize  = $true
$statusBar.Controls.Add($lblStatus)

# ================================================================
#  界面逻辑
# ================================================================
$script:Adapters  = @()
$script:CardInfo  = @()

function Set-Status {
    param([string]$Text, $Color = $null)
    $lblStatus.Text = $Text
    $lblStatus.ForeColor = if ($Color) { $Color } else { $C_Sub }
    $statusBar.Refresh()
    [Windows.Forms.Application]::DoEvents()
}

function Get-SelectedAdapter {
    $i = $listAdapters.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:Adapters.Count) { return $null }
    return $script:Adapters[$i]
}

function Get-CurrentDnsText {
    $a = Get-SelectedAdapter
    if (-not $a) { return '—' }
    $dns = Get-AdapterDns -IfIndex $a.ifIndex
    if ($dns.Count -eq 0) { return '自动获取（由路由器 / DHCP 下发）' }
    return ($dns -join '   ·   ')
}

function Update-CardStates {
    $a = Get-SelectedAdapter
    $cur = @()
    if ($a) { $cur = Get-AdapterDns -IfIndex $a.ifIndex }

    foreach ($ci in $script:CardInfo) {
        $match = $false
        if ($a) {
            $p = @($ci.Servers)
            if ($p.Count -eq 0 -and $cur.Count -eq 0) { $match = $true }
            elseif ($p.Count -eq $cur.Count -and $p.Count -gt 0) {
                $match = $true
                for ($k = 0; $k -lt $p.Count; $k++) {
                    if ($p[$k] -ne $cur[$k]) { $match = $false; break }
                }
            }
        }

        if ($match) {
            $ci.Panel.BackColor = $C_AccentBg
            $ci.Panel.Invalidate()
        }
        else {
            $ci.Panel.BackColor = $C_Card
            $ci.Panel.Invalidate()
        }
    }
}

function Update-CurrentDisplay {
    $a = Get-SelectedAdapter
    if ($a) {
        $stateText = switch ($a.Status) { 'Up' { '已连接' } 'Disconnected' { '未连接' } default { $a.Status } }
        $lblCurrent.Text = "$($a.Name)  [$stateText]  ·  $(Get-CurrentDnsText)"
    }
    else {
        $lblCurrent.Text = '请先选择一个网卡'
    }
    $lblCurrent.ForeColor = $C_Sub
    Update-CardStates
}

function Refresh-AdapterList {
    $prevName = $null
    $sel = Get-SelectedAdapter
    if ($sel) { $prevName = $sel.Name }

    $script:Adapters = @(Get-AdapterList -IncludeVirtual:$chkVirtual.Checked)

    $listAdapters.BeginUpdate()
    $listAdapters.Items.Clear()
    foreach ($a in $script:Adapters) {
        $stateText = switch ($a.Status) { 'Up' { '已连接' } 'Disconnected' { '未连接' } default { $a.Status } }
        [void]$listAdapters.Items.Add("$($a.Name)    · $stateText")
    }
    $listAdapters.EndUpdate()

    $pick = -1
    for ($i = 0; $i -lt $script:Adapters.Count; $i++) {
        if ($script:Adapters[$i].Name -eq $prevName) { $pick = $i; break }
    }
    if ($pick -lt 0) {
        for ($i = 0; $i -lt $script:Adapters.Count; $i++) {
            if ($script:Adapters[$i].Status -eq 'Up') { $pick = $i; break }
        }
    }
    if ($pick -lt 0 -and $script:Adapters.Count -gt 0) { $pick = 0 }

    if ($pick -ge 0) { $listAdapters.SelectedIndex = $pick }

    Update-CurrentDisplay
}

function Invoke-ApplyDns {
    param([string]$LabelText, [string[]]$Servers)

    $a = Get-SelectedAdapter
    if (-not $a) {
        Set-Status '请先选择一个网卡' $C_Warn
        return
    }

    Set-Status "正在切换 $($a.Name) → $LabelText ..."

    $r = Set-AdapterDns -IfIndex $a.ifIndex -Servers $Servers
    if ($r.Ok) {
        Update-CurrentDisplay
        Set-Status "✓ $($a.Name) 已切换为：$LabelText" $C_Ok
    }
    else {
        Set-Status "✗ 切换失败：$($r.Msg)" $C_Err
    }
}

# ---------- 生成预设卡片 ----------
$cardHandler = {
    param($sender, $e)
    $ctrl = $sender
    while ($null -ne $ctrl -and $null -eq $ctrl.Tag) { $ctrl = $ctrl.Parent }
    if ($null -ne $ctrl -and $null -ne $ctrl.Tag) {
        Invoke-ApplyDns -LabelText $ctrl.Tag.Name -Servers $ctrl.Tag.Servers
    }
}

foreach ($key in $Presets.Keys) {

    $servers = @($Presets[$key])
    $dns1Text = if ($servers.Count -gt 0) { $servers[0] } else { 'DHCP 自动下发' }
    $dns2Text = if ($servers.Count -gt 1) { $servers[1] } else { '' }

    $card = New-Object Windows.Forms.Panel
    $card.Size      = New-Object Drawing.Size(176, 68)
    $card.Margin    = New-Object Windows.Forms.Padding(2, 2, 2, 2)
    $card.BackColor = $C_Card
    $card.Cursor    = 'Hand'
    $card.Tag       = @{ Name = $key; Servers = $servers }

    # 边框自绘。坑：不要在 New-Object 的参数里写算术表达式
    # New-Object T(a, b, w - 1, h - 1) 会被 PowerShell 解析错（数组做减法 → op_Subtraction），
    # Paint 每次抛异常，WinForms 就把整块控件画成红叉。改用方法重载。
    $card.Add_Paint({
        param($sender, $e)
        $accentBg = [Drawing.Color]::FromArgb(232, 240, 254)
        $accent   = [Drawing.Color]::FromArgb(47, 111, 235)
        $border   = [Drawing.Color]::FromArgb(214, 221, 230)
        $line = if ($sender.BackColor -eq $accentBg) { $accent } else { $border }
        $pen = New-Object Drawing.Pen($line)
        $e.Graphics.DrawRectangle($pen, 0, 0, ($sender.Width - 1), ($sender.Height - 1))
        $pen.Dispose()
    })

    $lblName = New-Object Windows.Forms.Label
    $lblName.Text      = $key
    $lblName.Font      = $F_Bold
    $lblName.ForeColor = $C_Text
    $lblName.Location  = New-Object Drawing.Point(10, 8)
    $lblName.AutoSize  = $true
    $lblName.Cursor    = 'Hand'
    $lblName.BackColor = [Drawing.Color]::Transparent

    # 主 / 备 DNS 各占一行，避免长地址被卡片宽度截断
    $lblDns1 = New-Object Windows.Forms.Label
    $lblDns1.Text      = $dns1Text
    $lblDns1.Font      = $F_Tiny
    $lblDns1.ForeColor = $C_Sub
    $lblDns1.Location  = New-Object Drawing.Point(10, 29)
    $lblDns1.AutoSize  = $true
    $lblDns1.Cursor    = 'Hand'
    $lblDns1.BackColor = [Drawing.Color]::Transparent

    $lblDns2 = New-Object Windows.Forms.Label
    $lblDns2.Text      = $dns2Text
    $lblDns2.Font      = $F_Tiny
    $lblDns2.ForeColor = $C_Sub
    $lblDns2.Location  = New-Object Drawing.Point(10, 44)
    $lblDns2.AutoSize  = $true
    $lblDns2.Cursor    = 'Hand'
    $lblDns2.BackColor = [Drawing.Color]::Transparent
    $lblDns2.Visible   = ($servers.Count -gt 1)

    $card.Controls.Add($lblName)
    $card.Controls.Add($lblDns1)
    $card.Controls.Add($lblDns2)

    $card.Add_Click($cardHandler)
    $lblName.Add_Click($cardHandler)
    $lblDns1.Add_Click($cardHandler)
    $lblDns2.Add_Click($cardHandler)

    $flow.Controls.Add($card)

    $script:CardInfo += @{
        Name      = $key
        Servers   = $servers
        Panel     = $card
        Dns1Label = $lblDns1
        Dns1Text  = $dns1Text
        MainDns   = if ($servers.Count -gt 0) { $servers[0] } else { $null }
    }
}

# ---------- 事件绑定 ----------
$listAdapters.Add_SelectedIndexChanged({ Update-CurrentDisplay })
$chkVirtual.Add_CheckedChanged({ Refresh-AdapterList })
$btnRefresh.Add_Click({ Refresh-AdapterList; Set-Status '网卡列表已刷新' $C_Ok })

$btnTest.Add_Click({
    $btnTest.Enabled = $false
    $btnTest.Text = '测速中'
    try {
        foreach ($ci in $script:CardInfo) {
            if (-not $ci.MainDns) { continue }
            Set-Status "正在测速：$($ci.Name) → $($ci.MainDns) ..."
            $ms = Get-DnsLatency -Server $ci.MainDns
            $tag = if ($ms -ge 0) { "${ms}ms" } else { '无响应' }
            $ci.Dns1Label.Text = "$($ci.Dns1Text)    $tag"
        }
        Set-Status '✓ 测速完成（ICMP 延迟，仅供参考）' $C_Ok
    }
    finally {
        $btnTest.Text = '测速'
        $btnTest.Enabled = $true
    }
})

$btnApply.Add_Click({
    $list = @()
    foreach ($t in @($txtDns1.Text, $txtDns2.Text)) {
        $v = "$t".Trim()
        if ($v) { $list += $v }
    }
    if ($list.Count -eq 0) {
        Set-Status '请先填写至少一个 DNS 地址' $C_Warn
        return
    }
    foreach ($ip in $list) {
        $ok = $false
        $addr = $null
        $ok = [System.Net.IPAddress]::TryParse($ip, [ref]$addr)
        if (-not $ok -or $addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            Set-Status "✗ 不是合法的 IPv4 地址：$ip" $C_Err
            return
        }
    }
    Invoke-ApplyDns -LabelText "自定义 ($($list -join ', '))" -Servers $list
})

$btnFlush.Add_Click({
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Set-Status '✓ DNS 缓存已刷新' $C_Ok
    }
    catch {
        Set-Status "✗ 刷新缓存失败：$($_.Exception.Message)" $C_Err
    }
})

# ---------- 启动 ----------
Refresh-AdapterList
Set-Status "就绪 · 共 $($script:Adapters.Count) 个网卡（已隐藏虚拟网卡）"

if ($SelfTest) {
    # 把窗口挪到屏幕外再 Show，只为拿到真实 handle 与布局，不打扰使用者
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Location      = New-Object Drawing.Point(-4000, -4000)
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
    [Windows.Forms.Application]::DoEvents()

    # 顺带跑一次测速，验证卡片 Dns1Label 引用是否正确
    $btnTest.PerformClick()
    [Windows.Forms.Application]::DoEvents()

    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    $png = Join-Path $env:TEMP 'dns_selftest.png'
    $paintErr = ''
    try {
        $bmp  = New-Object Drawing.Bitmap($w, $h)
        $area = New-Object Drawing.Rectangle(0, 0, $w, $h)
        $form.DrawToBitmap($bmp, $area)
        $bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
    catch { $paintErr = $_.Exception.Message }

    Write-Host ''
    Write-Host ("SELFTEST | adapters=" + $script:Adapters.Count + " | cards=" + $script:CardInfo.Count)
    Write-Host ("form    = " + $w + " x " + $h)
    Write-Host ("paint   = " + $(if ($paintErr) { "FAIL: $paintErr" } else { "OK" }))
    Write-Host ("png     = " + $png)

    $form.Close()
    $form.Dispose()
    return
}

[void]$form.ShowDialog()
