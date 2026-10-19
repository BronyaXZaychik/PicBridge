param([switch]$NoUI)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class RoundBar : Control {
    public int Value { get; set; }
    public Color FillColor = Color.FromArgb(96, 160, 255);
    public Color TrackColor = Color.FromArgb(52, 58, 72);
    public Color TextColor = Color.FromArgb(235, 238, 245);
    public bool ShowTicks = false;
    public RoundBar() { DoubleBuffered = true; SetStyle(ControlStyles.SupportsTransparentBackColor, true); BackColor = Color.Transparent; }
    static GraphicsPath Round(Rectangle r, int radius) {
        var p = new GraphicsPath();
        int d = radius * 2;
        if (r.Width < d) { d = r.Width; }
        if (r.Height < d) { d = r.Height; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var full = new Rectangle(0, 0, Width - 1, Height - 1);
        int radius = Math.Max(3, Height / 2);
        using (var p = Round(full, radius)) using (var b = new SolidBrush(TrackColor)) g.FillPath(b, p);
        if (Value > 0) {
            int w = (int)((Width - 2) * Math.Min(100, Value) / 100.0);
            if (w < radius * 2) w = radius * 2;
            if (w > Width - 2) w = Width - 2;
            var r2 = new Rectangle(0, 0, w, Height - 1);
            using (var p2 = Round(r2, radius)) using (var b2 = new SolidBrush(FillColor)) g.FillPath(b2, p2);
        }
        if (ShowTicks) {
            using (var pen = new Pen(Color.FromArgb(70, 255, 255, 255), 1)) {
                for (int i = 10; i < 100; i += 10) {
                    int x = (int)((Width - 1) * i / 100.0);
                    g.DrawLine(pen, x, 0, x, Height - 1);
                }
            }
        }
        if (Height >= 14) {
            string s = Value + "%";
            using (var f = new Font("Segoe UI", Math.Max(6f, Height * 0.55f), FontStyle.Bold))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (var b3 = new SolidBrush(TextColor)) {
                g.DrawString(s, f, b3, new RectangleF(0, 0, Width, Height), sf);
            }
        }
    }
}
"@

$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgFile  = Join-Path $root '配置.json'
$cacheDir = Join-Path $root '缓存'
$pidFile  = Join-Path $root 'serve.pid'
$qrPng    = Join-Path $root '二维码.png'
$port     = 8765
$script:proc = $null
$script:stopping = $false
$script:mode = $cfg.mode
if ($script:mode -notin @('simple','standard','detail','custom')) { $script:mode = 'standard' }
$script:opts = @{ ticks = $false; names = 'short'; env = $false; dblclick = $true; qr = 2; bar = $true; ptext = $true; alpha = 85; purge_now = $false; convert_heic = $true }
$script:py = $null
$script:bg = $null

function Read-Cfg {
    $dirs = @(); $mode = 'standard'
    $opts = @{ ticks = $false; names = 'short'; env = $false; dblclick = $true; qr = 2; bar = $true; ptext = $true; alpha = 85; purge_now = $false; convert_heic = $true }
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $o = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($d in $o.dirs) { if ($d) { $d = [string]$d; if (-not [IO.Path]::IsPathRooted($d)) { $d = Join-Path $root $d }; $dirs += $d } }
            if ($o.mode) { $mode = [string]$o.mode }
            if ($o.opts) {
                if ($null -ne $o.opts.ticks) { $opts.ticks = [bool]$o.opts.ticks }
                if ($o.opts.names) { $opts.names = [string]$o.opts.names }
                if ($null -ne $o.opts.env) { $opts.env = [bool]$o.opts.env }
                if ($null -ne $o.opts.dblclick) { $opts.dblclick = [bool]$o.opts.dblclick }
                if ($null -ne $o.opts.bar) { $opts.bar = [bool]$o.opts.bar }
                if ($null -ne $o.opts.ptext) { $opts.ptext = [bool]$o.opts.ptext }
                if ($null -ne $o.opts.alpha) { $opts.alpha = [int]$o.opts.alpha }
                if ($null -ne $o.opts.qr) { $opts.qr = [int]$o.opts.qr }
                if ($null -ne $o.opts.alpha) { $opts.alpha = [int]$o.opts.alpha }
            }
        } catch {}
    }
    # 默认不预置目录，由用户自己添加
    return @{ dirs = $dirs; mode = $mode; opts = $opts }
}
function Save-Cfg($dirs, $mode, $opts) {
    $o = [ordered]@{ dirs = @($dirs); mode = $mode; opts = $opts }
    [IO.File]::WriteAllText($cfgFile, ($o | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}
function Get-Python {
    $rt = Join-Path $root 'runtime\python.exe'
    if (Test-Path -LiteralPath $rt) { return @{ Exe = $rt; Args = @() } }
    foreach ($c in @('python', 'python3')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { & $cmd.Source -c "import sys" 2>$null; if ($LASTEXITCODE -eq 0) { return @{ Exe = $cmd.Source; Args = @() } } }
    }
    $py = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($py) { & $py.Source -3 -c "import sys" 2>$null; if ($LASTEXITCODE -eq 0) { return @{ Exe = $py.Source; Args = @('-3') } } }
    foreach ($pat in @("$env:LOCALAPPDATA\Programs\Python\Python31*\python.exe", "$env:ProgramFiles\Python31*\python.exe")) {
        $f = Get-ChildItem $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return @{ Exe = $f.FullName; Args = @() } }
    }
    return $null
}
function Test-Port {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $r = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne(400)
        if ($ok) { $c.EndConnect($r) }
        $c.Close(); return $ok
    } catch { return $false }
}
function Get-LanIp {
    $cands = @()
    try {
        $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop
        foreach ($a in $addrs) {
            $ip = [string]$a.IPAddress
            $alias = [string]$a.InterfaceAlias
            if ($ip -like '127.*' -or $ip -like '169.254.*') { continue }
            if ($alias -match 'vEthernet|VMware|Virtual|Loopback|TAP|VPN|ZOO|Hyper-V|Bluetooth|WSL|Docker') { continue }
            if ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)') { $cands += @{ ip = $ip; alias = $alias } }
        }
    } catch {}
    if ($cands.Count -gt 0) {
        foreach ($c in $cands) { if ($c.alias -match 'Ethernet|以太网|本地连接|LAN') { return $c.ip } }
        return $cands[0].ip
    }
    foreach ($target in @('223.5.5.5', '114.114.114.114', '8.8.8.8')) {
        try {
            $s = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
            $s.Connect($target, 80)
            $ip = $s.LocalEndPoint.Address.ToString()
            $s.Close()
            if ($ip -and $ip -ne '0.0.0.0' -and $ip -notlike '127.*') { return $ip }
        } catch {}
    }
    return '127.0.0.1'
}
function Short-Name($n) {
    if (-not $n) { return '' }
    $n = $n.Trim()
    if ($n.Length -le 12) { return $n }
    return $n.Substring(0, 12) + '…'
}
function Get-CacheCount {
    if (-not (Test-Path -LiteralPath $cacheDir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $cacheDir -Recurse -File -Filter *.webp -ErrorAction SilentlyContinue).Count
}
function Clear-Cache {
    $n = Get-CacheCount
    if (Test-Path -LiteralPath $cacheDir) {
        Get-ChildItem -LiteralPath $cacheDir -Recurse -File -Filter *.webp -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return $n
}

$cfg = Read-Cfg
$script:mode = $cfg.mode
if ($script:mode -notin @('simple','standard','detail','custom')) { $script:mode = 'standard' }
$script:opts = $cfg.opts

if ($NoUI) {
    $py = Get-Python
    if (-not $py) { exit 1 }
    $dirs = @($cfg.dirs | Where-Object { Test-Path -LiteralPath $_ })
    if ($dirs.Count -eq 0) { exit 2 }
    $a = @(); $a += $py.Args; $a += "`"$root\serve.py`""
    foreach ($d in $dirs) { $a += "`"$d`"" }
    if (-not $script:opts.convert_heic) { $a += '--no-convert-heic' }
    $a += @('--cache', "`"$cacheDir`"", '--workers', '2', '--watch-interval', '5')
    Start-Process -FilePath $py.Exe -ArgumentList $a -WindowStyle Hidden | Out-Null
    exit 0
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$bgc   = [Drawing.Color]::FromArgb(24, 26, 33)
$card  = [Drawing.Color]::FromArgb(38, 43, 54)
$fg    = [Drawing.Color]::FromArgb(236, 239, 246)
$dim   = [Drawing.Color]::FromArgb(168, 176, 190)
$accent= [Drawing.Color]::FromArgb(86, 148, 255)
$okc   = [Drawing.Color]::FromArgb(96, 214, 148)
$badc  = [Drawing.Color]::FromArgb(242, 118, 118)

$form = New-Object Windows.Forms.Form
$form.Text = '图片查看器（局域网版本）'
$form.ClientSize = New-Object Drawing.Size(940, 560)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bgc
$form.ForeColor = $fg
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9.5)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
try {
    $pi = $form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
    if ($pi) { $pi.SetValue($form, $true) }
} catch {}
$form.AllowDrop = $true
$ico = Join-Path $root '图标.ico'
if (Test-Path -LiteralPath $ico) { try { $form.Icon = New-Object Drawing.Icon($ico) } catch {} }

$bgPath = Join-Path $root '背景.jpg'
if (Test-Path -LiteralPath $bgPath) {
    try {
        $raw = [Drawing.Image]::FromFile($bgPath)
        $cm = New-Object Drawing.Imaging.ColorMatrix
        $cm.Matrix00 = 0.72; $cm.Matrix11 = 0.72; $cm.Matrix22 = 0.72
        $cm.Matrix33 = 1.0;  $cm.Matrix44 = 1.0
        $ia = New-Object Drawing.Imaging.ImageAttributes
        $ia.SetColorMatrix($cm)
        $dark = New-Object Drawing.Bitmap($raw.Width, $raw.Height)
        $gd = [Drawing.Graphics]::FromImage($dark)
        $gd.DrawImage($raw, (New-Object Drawing.Rectangle(0, 0, $raw.Width, $raw.Height)), 0, 0, $raw.Width, $raw.Height, [Drawing.GraphicsUnit]::Pixel, $ia)
        $gd.Dispose(); $raw.Dispose()
        $script:bg = $dark
    } catch { $script:bg = $null }
}

function Round-Ctrl($c, $radius) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $w = $c.Width; $h = $c.Height; $d = $radius * 2
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($w - $d, 0, $d, $d, 270, 90)
    $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $p.AddArc(0, $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $c.Region = New-Object Drawing.Region($p)
}

function New-Label($text, $x, $y, $w, $h, $size, $color) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y)
    $l.Size = New-Object Drawing.Size($w, $h)
    $l.Font = New-Object Drawing.Font('Microsoft YaHei UI', $size)
    $l.ForeColor = $color; $l.BackColor = [Drawing.Color]::Transparent
    return $l
}
function New-Btn($text, $x, $y, $w, $h, $color) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y)
    $b.Size = New-Object Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $color; $b.ForeColor = [Drawing.Color]::White
    $b.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $b.Cursor = 'Hand'
    Round-Ctrl $b 8
    return $b
}

# 背景绘制
$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $cw = $form.ClientSize.Width; $ch = $form.ClientSize.Height
    if ($script:bg) {
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $iw = $script:bg.Width; $ih = $script:bg.Height
        $sc = [Math]::Max($cw / $iw, $ch / $ih)
        $dw = $iw * $sc; $dh = $ih * $sc
        $dx = $cw - $dw          # 右对齐，保证人物在画面里
        $dy = ($ch - $dh) / 2
        $g.DrawImage($script:bg, [Drawing.RectangleF]::new($dx, $dy, $dw, $dh))
    }
    $ov = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(186, 18, 20, 27))
    $g.FillRectangle($ov, 0, 0, $cw, $ch)
    $ov.Dispose()
})

# ---- 卡片 ----
$panelLeft = New-Object Windows.Forms.Panel
$panelLeft.Location = New-Object Drawing.Point(20, 20)
$panelLeft.Size = New-Object Drawing.Size(340, 520)
$panelLeft.BackColor = $card
Round-Ctrl $panelLeft 14
$form.Controls.Add($panelLeft)

$panelRight = New-Object Windows.Forms.Panel
$panelRight.Location = New-Object Drawing.Point(376, 20)
$panelRight.Size = New-Object Drawing.Size(544, 520)
$panelRight.BackColor = $card
Round-Ctrl $panelRight 14
$form.Controls.Add($panelRight)

# ---- 顶部：模式选择 ----
$cmbMode = New-Object Windows.Forms.ComboBox
$cmbMode.DropDownStyle = 'DropDownList'
$cmbMode.Location = New-Object Drawing.Point(760, -2)
$cmbMode.Size = New-Object Drawing.Size(150, 26)
[void]$cmbMode.Items.AddRange(@('简洁模式', '标准模式', '详细模式', '自定义'))
$panelLeft.Controls.Add($cmbMode)
$cmbMode.SelectedIndex = switch ($script:mode) { 'simple' { 0 } 'detail' { 2 } 'custom' { 3 } default { 1 } }
$cmbMode.Visible = $false

$btnSettings = New-Btn '设置' 250 12 74 26 ([Drawing.Color]::FromArgb(56, 62, 76))
$panelLeft.Controls.Add($btnSettings)

# ---- 左卡片内容 ----
$lblTitle = New-Label '图片查看器 · 局域网' 16 14 300 26 13 $fg
$panelLeft.Controls.Add($lblTitle)
$lblEnv = New-Label '' 16 46 308 20 8.5 $dim
$panelLeft.Controls.Add($lblEnv)
$lblStatus = New-Label '● 服务未启动' 16 72 300 22 10 $badc
$panelLeft.Controls.Add($lblStatus)

$btnStart = New-Btn '启动服务' 16 104 150 44 $accent
$btnStop  = New-Btn '断开并停止' 174 104 150 44 ([Drawing.Color]::FromArgb(64, 70, 86))
$panelLeft.Controls.Add($btnStart); $panelLeft.Controls.Add($btnStop)

$lblUrlCap = New-Label '手机浏览器打开（同一 Wi-Fi）' 16 160 300 20 8.5 $dim
$txtUrl = New-Object Windows.Forms.TextBox
$txtUrl.Location = New-Object Drawing.Point(16, 182)
$txtUrl.Size = New-Object Drawing.Size(236, 28)
$txtUrl.ReadOnly = $true; $txtUrl.BorderStyle = 'FixedSingle'
$txtUrl.BackColor = [Drawing.Color]::FromArgb(46, 52, 64); $txtUrl.ForeColor = $okc
$txtUrl.Font = New-Object Drawing.Font('Consolas', 10.5)
$btnCopy = New-Btn '复制' 258 182 66 28 ([Drawing.Color]::FromArgb(56, 62, 76))
$panelLeft.Controls.Add($lblUrlCap); $panelLeft.Controls.Add($txtUrl); $panelLeft.Controls.Add($btnCopy)

$lblDirCount = New-Label '已连接 0 个目录' 16 222 300 22 9.5 $dim
$panelLeft.Controls.Add($lblDirCount)

$btnClear = New-Btn '清空缓存' 16 252 308 32 ([Drawing.Color]::FromArgb(56, 62, 76))
$panelLeft.Controls.Add($btnClear)

$lblLog = New-Label '' 16 296 308 260 8.5 $dim
$panelLeft.Controls.Add($lblLog)

# ---- 右卡片：目录 ----
$lblDirs = New-Label '已连接的目录' 16 12 300 22 10 $fg
$panelRight.Controls.Add($lblDirs)
$listBox = New-Object Windows.Forms.ListBox
$listBox.Location = New-Object Drawing.Point(16, 40)
$listBox.Size = New-Object Drawing.Size(300, 240)
$listBox.BackColor = [Drawing.Color]::FromArgb(46, 52, 64); $listBox.ForeColor = $fg
$listBox.BorderStyle = 'FixedSingle'
$listBox.BorderStyle = 'None'
$listBox.HorizontalScrollbar = $false
$panelRight.Controls.Add($listBox)

$tipDirs = New-Object Windows.Forms.ToolTip
$tipDirs.AutoPopDelay = 20000
$tipDirs.InitialDelay = 350
$tipDirs.ReshowDelay = 150
$script:lastIdx = -1
$listBox.Add_MouseMove({
    param($s, $e)
    $i = $listBox.IndexFromPoint($e.Location)
    if ($i -ne $script:lastIdx) {
        $script:lastIdx = $i
        if ($i -ge 0) {
            $dd = @((Read-Cfg).dirs)
            if ($i -lt $dd.Count) { $tipDirs.SetToolTip($listBox, [string]$dd[$i]) }
        }
    }
})
$listBox.DrawMode = 'OwnerDrawFixed'
$listBox.ItemHeight = 22
$listBox.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $g = $e.Graphics
    if ((($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) -or (($e.State -band [System.Windows.Forms.DrawItemState]::Focused) -ne 0 -and $false)) {
        $br0 = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(70, 96, 160, 255))
        $g.FillRectangle($br0, $e.Bounds)
        $br0.Dispose()
    }
    $bgimg = $s.BackgroundImage
    if ($bgimg) { $g.DrawImage($bgimg, $e.Bounds, $e.Bounds, [Drawing.GraphicsUnit]::Pixel) }
    $txt = [string]$s.Items[$e.Index]
    $f = $s.Font
    $sh = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(190, 0, 0, 0))
    $g.DrawString($txt, $f, $sh, ($e.Bounds.X + 9), ($e.Bounds.Y + 3))
    $sh.Dispose()
    $fg2 = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(240, 243, 250))
    $g.DrawString($txt, $f, $fg2, ($e.Bounds.X + 8), ($e.Bounds.Y + 2))
    $fg2.Dispose()
})


$btnAdd      = New-Btn '添加目录…' 16 228 120 32 $accent
$btnRemove   = New-Btn '移除'       144 228 76 32 ([Drawing.Color]::FromArgb(56, 62, 76))
$btnClearAll = New-Btn '全清'       228 228 88 32 ([Drawing.Color]::FromArgb(56, 62, 76))
$panelRight.Controls.Add($btnAdd); $panelRight.Controls.Add($btnRemove); $panelRight.Controls.Add($btnClearAll)

# 进度
$lblTotal = New-Label '轻量图总进度' 16 272 300 20 8.5 $dim
$panelRight.Controls.Add($lblTotal)
$barTotal = New-Object RoundBar
$barTotal.Location = New-Object Drawing.Point(16, 294)
$barTotal.Size = New-Object Drawing.Size(300, 22)
$panelRight.Controls.Add($barTotal)

$script:rows = @()
for ($i = 0; $i -lt 4; $i++) {
    $y = 326 + $i * 34
    $l = New-Label '' 16 $y 300 18 8.5 $dim
    $b = New-Object RoundBar
    $b.Location = New-Object Drawing.Point(16, ($y + 18))
    $b.Size = New-Object Drawing.Size(300, 14)
    $panelRight.Controls.Add($l); $panelRight.Controls.Add($b)
    $script:rows += @{ label = $l; bar = $b }
}

# 二维码
$picQR = New-Object Windows.Forms.PictureBox
$picQR.Location = New-Object Drawing.Point(344, 40)
$picQR.Size = New-Object Drawing.Size(180, 180)
$picQR.SizeMode = 'Zoom'
$picQR.BackColor = [Drawing.Color]::White
$panelRight.Controls.Add($picQR)
$lblQR = New-Label '扫码直接用手机打开' 0 0 1 1 8 $dim
$lblQR.Visible = $false

# 自定义选项面板
$panelOpts = New-Object Windows.Forms.Panel
$panelOpts.Location = New-Object Drawing.Point(344, 40)
$panelOpts.Size = New-Object Drawing.Size(184, 334)
$panelOpts.BackColor = [Drawing.Color]::FromArgb(46, 52, 64)
Round-Ctrl $panelOpts 10
$panelRight.Controls.Add($panelOpts)
$panelOpts.Visible = $false


$lblNames = New-Label '目录名显示' 10 36 160 18 8.5 $dim
$cmbNames = New-Object Windows.Forms.ComboBox
$cmbNames.DropDownStyle = 'DropDownList'
$cmbNames.Location = New-Object Drawing.Point(10, 56); $cmbNames.Size = New-Object Drawing.Size(160, 24)
[void]$cmbNames.Items.AddRange(@('全部', '简洁', '不显示'))
$cmbNames.SelectedIndex = switch ($script:opts.names) { 'full' { 0 } 'none' { 2 } default { 1 } }
$panelOpts.Controls.Add($lblNames); $panelOpts.Controls.Add($cmbNames)

$chkEnv = New-Object Windows.Forms.CheckBox
$chkEnv.Text = '显示环境信息'; $chkEnv.ForeColor = $fg
$chkEnv.Location = New-Object Drawing.Point(10, 88); $chkEnv.Size = New-Object Drawing.Size(164, 22)
$chkEnv.Checked = $script:opts.env
$panelOpts.Controls.Add($chkEnv)

$chkDbl = New-Object Windows.Forms.CheckBox
$chkDbl.Text = '双击打开目录'; $chkDbl.ForeColor = $fg
$chkDbl.Location = New-Object Drawing.Point(10, 112); $chkDbl.Size = New-Object Drawing.Size(164, 22)
$chkDbl.Checked = $script:opts.dblclick
$panelOpts.Controls.Add($chkDbl)

$chkBar = New-Object Windows.Forms.CheckBox
$chkBar.Text = '显示进度条'; $chkBar.ForeColor = $fg
$chkBar.Location = New-Object Drawing.Point(10, 140); $chkBar.Size = New-Object Drawing.Size(164, 22)
$chkBar.Checked = [bool]$script:opts.bar
$panelOpts.Controls.Add($chkBar)

$chkPtext = New-Object Windows.Forms.CheckBox
$chkPtext.Text = '显示百分比文字'; $chkPtext.ForeColor = $fg
$chkPtext.Location = New-Object Drawing.Point(10, 164); $chkPtext.Size = New-Object Drawing.Size(164, 22)
$chkPtext.Checked = [bool]$script:opts.ptext
$panelOpts.Controls.Add($chkPtext)

$panelOpts.Controls.Add((New-Label '界面透明度' 10 192 160 18 8.5 $dim))
$tbDim = New-Object Windows.Forms.TrackBar
$tbDim.Minimum = 30; $tbDim.Maximum = 100; $tbDim.TickFrequency = 10
$tbDim.Location = New-Object Drawing.Point(10, 210); $tbDim.Size = New-Object Drawing.Size(160, 30)
$tbDim.Value = [Math]::Max(30, [Math]::Min(100, [int]$script:opts.alpha))
$panelOpts.Controls.Add($tbDim)

$chkPurge = New-Object Windows.Forms.CheckBox
$chkPurge.Text = '移除目录时立即清缓存'; $chkPurge.ForeColor = $fg
$chkPurge.Location = New-Object Drawing.Point(10, 252); $chkPurge.Size = New-Object Drawing.Size(168, 22)
$chkPurge.Checked = [bool]$script:opts.purge_now
$panelOpts.Controls.Add($chkPurge)

$chkConv = New-Object Windows.Forms.CheckBox
$chkConv.Text = 'HEIC/AVIF 转 JPG'; $chkConv.ForeColor = $fg
$chkConv.Location = New-Object Drawing.Point(10, 282); $chkConv.Size = New-Object Drawing.Size(168, 22)
$chkConv.Checked = [bool]$script:opts.convert_heic
$panelOpts.Controls.Add($chkConv)


function Add-Log($m) { $lblLog.Text = $m }

function Eff($key) {
    if ($script:mode -eq 'custom') { return $script:opts[$key] }
    switch ($key) {
        'names'    { if ($script:mode -eq 'detail') { return 'full' } return 'short' }
        'env'      { return ($script:mode -eq 'detail') }
        'ticks'    { return $false }
        'dblclick' { return ($script:mode -eq 'custom' -and $script:opts.dblclick) }
        'qr'       { return 2 }
    }
    return $null
}

function Refresh-List {
    $listBox.Items.Clear()
    foreach ($d in @((Read-Cfg).dirs)) {
        $mark = '×'
        if (Test-Path -LiteralPath $d) { $mark = '✓' }
        $leaf = Split-Path $d -Leaf
        $show = $leaf
        if ($script:mode -eq 'detail' -or (Eff 'names') -eq 'full') { $show = $d }
        elseif ((Eff 'names') -eq 'short') { $show = Short-Name $leaf }
        elseif ((Eff 'names') -eq 'none') { $show = '' }
        [void]$listBox.Items.Add("$mark  $show")
    }
}
function Fit-List {
    try {
        $h = $listBox.Items.Count * 22 + 6
        if ($h -lt 26) { $h = 26 }
        if ($h -gt 240) { $h = 240 }
        $listBox.Height = $h
    } catch {}
}

function Get-Dirs {
    $cfgNow = Read-Cfg
    return @($cfgNow.dirs)
}

function Update-QR($url) {
    if (-not $url -or -not $script:py) { $picQR.Visible = $false; $lblQR.Visible = $false; return }
    try {
        $vendor = Join-Path $root 'vendor'
        $code = "import sys;sys.path.insert(0,r'$vendor');import segno;segno.make(r'$url',error='m').save(r'$qrPng',scale=10,border=2,dark='#1a1c22',light='#ffffff')"
        $a = @(); $a += $script:py.Args; $a += @('-c', $code)
        & $script:py.Exe @a 2>$null | Out-Null
        if (Test-Path -LiteralPath $qrPng) {
            $bytes = [IO.File]::ReadAllBytes($qrPng)
            $ms = New-Object IO.MemoryStream(, $bytes)
            $picQR.Image = [Drawing.Image]::FromStream($ms)
            $picQR.Visible = $true
            $lblQR.Size = New-Object Drawing.Size(200, 20)
            $lblQR.Visible = $true
            $picQR.BringToFront()
        }
    } catch {}
}

function Update-Progress {
    if (-not (Test-Port)) { return }
    if ($script:mode -eq 'simple') {
        foreach ($row in $script:rows) { $row.label.Visible = $false; $row.bar.Visible = $false }
        return
    }
    try { $p = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $port + "/api/progress") -TimeoutSec 3 } catch { return }
    $pct = 0
    if ([int]$p.total -gt 0) { $pct = [int](100.0 * $p.done / $p.total) }
    $barTotal.Visible = (($script:mode -ne 'standard') -and ($script:mode -ne 'custom' -or $script:opts.bar))
    $barTotal.Value = $pct
    $lblTotal.Text = "轻量图总进度  " + $pct + "%   (" + $p.done + " / " + $p.total + ")"
    $barTotal.Invalidate()

    $roots = @($p.roots)
    for ($i = 0; $i -lt 4; $i++) {
        $row = $script:rows[$i]
        if ($i -lt $roots.Count) {
            $r = $roots[$i]
            $rp = 0
            if ([int]$r.total -gt 0) { $rp = [int](100.0 * $r.done / $r.total) }
            $nm = [string]$r.name
            if ((Eff 'names') -eq 'none') { $nm = '目录' + ($i + 1) }
            elseif ((Eff 'names') -eq 'short') { $nm = Short-Name $nm }
            $row.label.Text = $nm
            $row.label.Visible = ($script:mode -ne 'custom' -or $script:opts.ptext)
            $row.bar.Value = $rp
            $row.bar.Invalidate()
            $row.bar.Visible = (($script:mode -ne 'standard') -and ($script:mode -ne 'custom' -or $script:opts.bar))
        } else {
            $row.label.Visible = $false
            $row.bar.Visible = $false
        }
    }
}

function Apply-Mode($m) {
    $script:mode = $m
    $simple = ($m -eq 'simple')
    $detail = ($m -eq 'detail')
    $custom = ($m -eq 'custom')

    if ($simple) {
        $form.ClientSize = New-Object Drawing.Size(640, 420)
        $panelLeft.Visible = $false
        $panelRight.Location = New-Object Drawing.Point(20, 20)
        $panelRight.Size = New-Object Drawing.Size(600, 380)
        $btnStart.Parent = $panelRight; $btnStop.Parent = $panelRight
        $btnStart.Location = New-Object Drawing.Point(16, 300); $btnStart.Size = New-Object Drawing.Size(150, 46)
        $btnStop.Location = New-Object Drawing.Point(176, 300); $btnStop.Size = New-Object Drawing.Size(150, 46)
        $lblDirCount.Parent = $panelRight
        $lblDirCount.Location = New-Object Drawing.Point(16, 262); $lblDirCount.Size = New-Object Drawing.Size(300, 22)
        $lblDirCount.Visible = $false
        $lblDirs.Visible = $false; $listBox.Visible = $false
        $btnAdd.Visible = $false; $btnRemove.Visible = $false; $btnClearAll.Visible = $false
        $lblTotal.Visible = $false; $barTotal.Visible = $false
        foreach ($row in $script:rows) { $row.label.Visible = $false; $row.bar.Visible = $false }
        $picQR.Parent = $panelRight; $lblQR.Parent = $panelRight
        $picQR.Size = New-Object Drawing.Size(190, 190)
        $picQR.Location = New-Object Drawing.Point(16, 48)
        $lblQR.Size = New-Object Drawing.Size(200, 20)
        $lblQR.Location = New-Object Drawing.Point(16, 244)
        if ($picQR.Image) { $picQR.Visible = $true; $lblQR.Visible = $true } else { $picQR.Visible = $false; $lblQR.Visible = $false }
    } else {
        $form.ClientSize = New-Object Drawing.Size(940, 560)
        $panelLeft.Visible = $true
        $panelLeft.Size = New-Object Drawing.Size(340, 520)
        $panelRight.Location = New-Object Drawing.Point(376, 20)
        $panelRight.Size = New-Object Drawing.Size(544, 520)
        $btnStart.Parent = $panelLeft; $btnStop.Parent = $panelLeft
        $btnStart.Location = New-Object Drawing.Point(16, 104); $btnStart.Size = New-Object Drawing.Size(150, 44)
        $btnStop.Location = New-Object Drawing.Point(174, 104); $btnStop.Size = New-Object Drawing.Size(150, 44)
        $lblDirCount.Parent = $panelLeft
        $lblDirCount.Location = New-Object Drawing.Point(16, 222); $lblDirCount.Size = New-Object Drawing.Size(300, 22)
        $lblDirCount.Visible = $false
        $lblDirs.Visible = $true; $listBox.Visible = $true
        $btnAdd.Visible = $true; $btnRemove.Visible = $true; $btnClearAll.Visible = $true
        $lblTotal.Visible = $true; $barTotal.Visible = $true
        $picQR.Parent = $panelLeft; $lblQR.Parent = $panelLeft
        $qsz = 150
        $picQR.Size = New-Object Drawing.Size($qsz, $qsz)
        $picQR.Location = New-Object Drawing.Point(([int]((340 - $qsz) / 2)), (520 - $qsz - 40))
        $lblQR.Size = New-Object Drawing.Size(200, 20)
        $lblQR.Location = New-Object Drawing.Point(([int]((340 - 200) / 2)), (520 - 30))
        if ($picQR.Image) { $picQR.Visible = $true; $lblQR.Visible = $true } else { $picQR.Visible = $false; $lblQR.Visible = $false }
    }

    if ($simple) {
        $btnSettings.Parent = $panelRight
        $btnSettings.Location = New-Object Drawing.Point(16, 8)
    } else {
        $btnSettings.Parent = $panelLeft
        $btnSettings.Location = New-Object Drawing.Point(250, 12)
    }
    $btnSettings.Visible = $true
    $btnSettings.BringToFront()

    $lblEnv.Visible = ($detail -or [bool](Eff 'env'))
    $txtUrl.Visible = (-not $simple)
    $lblUrlCap.Visible = (-not $simple)
    $btnCopy.Visible = (-not $simple)
    $btnClear.Visible = (-not $simple)
    $lblLog.Visible = $detail

    $panelOpts.Visible = $custom
    $step = 34
    if ($script:mode -eq 'standard') { $step = 25 }
    for ($i = 0; $i -lt 4; $i++) {
        $ry = 320 + $i * $step
        $script:rows[$i].label.Location = New-Object Drawing.Point(16, $ry)
        $script:rows[$i].bar.Location = New-Object Drawing.Point(16, ($ry + 16))
    }
    Save-Cfg (Read-Cfg).dirs $m $script:opts
    Update-PanelAlpha
    Blend-Controls
    try {
        $img2 = $panelRight.BackgroundImage
        if ($img2) {
            $lr = New-Object Drawing.Rectangle($listBox.Left, $listBox.Top, $listBox.Width, $listBox.Height)
            $lr.Intersect((New-Object Drawing.Rectangle(0, 0, $img2.Width, $img2.Height)))
            if ($lr.Width -gt 2 -and $lr.Height -gt 2) {
                $crop = New-Object Drawing.Bitmap($lr.Width, $lr.Height)
                $g3 = [Drawing.Graphics]::FromImage($crop)
                $g3.DrawImage($img2, (New-Object Drawing.Rectangle(0, 0, $lr.Width, $lr.Height)), $lr, [Drawing.GraphicsUnit]::Pixel)
                $g3.Dispose()
                $listBox.BackgroundImage = $crop
                $listBox.BackgroundImageLayout = 'None'
                try { $listBox.BackColor = $crop.GetPixel([int]($crop.Width / 2), $crop.Height - 3) } catch {}
            }
        }
    } catch {}
    Refresh-List
    Fit-List
    if (Test-Port) { Update-Progress; Update-QR $txtUrl.Text }
}

function Refresh-Env {
    $script:py = Get-Python
    if (-not $script:py) { $lblEnv.Text = '环境：未找到 Python'; $lblEnv.ForeColor = $badc; $btnStart.Enabled = $false; return $false }
    $ver = & $script:py.Exe @($script:py.Args + @('--version')) 2>$null
    $pil = & $script:py.Exe @($script:py.Args + @('-c', 'import PIL;print(PIL.__version__)')) 2>$null
    if ([string]::IsNullOrWhiteSpace($pil)) { $lblEnv.Text = "环境：$ver（缺 Pillow）"; $lblEnv.ForeColor = [Drawing.Color]::FromArgb(240, 190, 90) }
    else { $lblEnv.Text = "环境：$ver  ·  Pillow $pil"; $lblEnv.ForeColor = $okc }
    $btnStart.Enabled = $true
    return $true
}

function Update-ServerState {
    if (Test-Port) {
        $lblStatus.Text = '● 运行中'; $lblStatus.ForeColor = $okc
        $txtUrl.Text = 'http://' + (Get-LanIp) + ':' + $port + '/'
        if (-not $script:stopping) { $btnStart.Enabled = $false }
        $btnStop.Enabled = $true
        if (-not $picQR.Image) { Update-QR $txtUrl.Text }
        if ($picQR.Image) { $picQR.Visible = $true; $lblQR.Visible = $true }
    } else {
        $lblStatus.Text = '● 未启动'; $lblStatus.ForeColor = $badc
        $btnStart.Enabled = $true; $btnStop.Enabled = $false
        $picQR.Visible = $false; $lblQR.Visible = $false
    }
}

function Start-Service2 {
    $dirs = @((Read-Cfg).dirs)
    $valid = @()
    foreach ($d in $dirs) { if (Test-Path -LiteralPath $d) { $valid += $d } }
    if ($valid.Count -eq 0) { Add-Log '没有可用目录，请先添加。'; return }
    Save-Cfg $valid $script:mode $script:opts
    if (Test-Port) { Add-Log '服务已在运行（目录改动会自动热加载）。'; Update-ServerState; return }
    if (-not $script:py) { Add-Log '没有找到 Python。'; return }
    $a = @(); $a += $script:py.Args; $a += "`"$root\serve.py`""
    foreach ($d in $valid) { $a += "`"$d`"" }
    if (-not $script:opts.convert_heic) { $a += '--no-convert-heic' }
    $a += @('--cache', "`"$cacheDir`"", '--workers', '2', '--watch-interval', '5')
    $script:proc = Start-Process -FilePath $script:py.Exe -ArgumentList $a -WindowStyle Hidden -PassThru
    try { [IO.File]::WriteAllText($pidFile, [string]$script:proc.Id, [Text.Encoding]::ASCII) } catch {}
    Start-Sleep -Milliseconds 1600
    Update-ServerState
    Update-QR $txtUrl.Text
    Update-Progress
    # 目录数量不再显示
    Add-Log ('已启动，共 ' + $valid.Count + ' 个目录')
}

function Stop-Service2 {
    $script:stopping = $true
    try { [IO.File]::WriteAllText((Join-Path $root 'stop.flag'), '1', [Text.Encoding]::ASCII) } catch {}
    if (Test-Path -LiteralPath $pidFile) {
        $p = (Get-Content $pidFile -Raw).Trim()
        if ($p) { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $root 'stop.flag') -Force -ErrorAction SilentlyContinue
    $script:proc = $null
    $barTotal.Value = 0
    foreach ($row in $script:rows) { $row.label.Visible = $false; $row.bar.Visible = $false }
    Add-Log '已断开连接（服务停止）。'
    Start-Sleep -Milliseconds 400
    Update-ServerState
}

# ---- 事件 ----
$cmbMode.Add_SelectedIndexChanged({
    $m = switch ($cmbMode.SelectedIndex) { 0 { 'simple' } 2 { 'detail' } 3 { 'custom' } default { 'standard' } }
    Apply-Mode $m
})

$btnAdd.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择要加入的图片文件夹'
    if ($dlg.ShowDialog() -eq 'OK') {
        $dirs = @((Read-Cfg).dirs)
        if (-not ($dirs -contains $dlg.SelectedPath)) {
            $dirs += $dlg.SelectedPath
            Save-Cfg $dirs $script:mode $script:opts
            Refresh-List
            Fit-List
            Add-Log ('已添加（热加载，几秒内生效）：' + $dlg.SelectedPath)
        }
    }
})
$btnRemove.Add_Click({
    if ($listBox.SelectedIndex -ge 0) {
        $dirs = @((Read-Cfg).dirs)
        if ($listBox.SelectedIndex -lt $dirs.Count) {
            $dirs = @($dirs | Where-Object { $_ -ne $dirs[$listBox.SelectedIndex] })
            Save-Cfg $dirs $script:mode $script:opts
            Refresh-List
            Fit-List
            if ($script:opts.purge_now -and (Test-Port)) { try { Invoke-WebRequest ('http://127.0.0.1:' + $port + '/api/purge') -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {} }
            Add-Log '已移除（热加载生效）'
        }
    }
})
$btnClearAll.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('清空目录列表？（不会删除任何文件）', '确认', 'YesNo', 'Question') -eq 'Yes') {
        Save-Cfg @() $script:mode $script:opts
        Refresh-List
        if ($script:opts.purge_now -and (Test-Port)) { try { Invoke-WebRequest ('http://127.0.0.1:' + $port + '/api/purge') -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {} }
    }
})
$btnStart.Add_Click({ Start-Service2 })
$btnStop.Add_Click({ Stop-Service2 })
$btnClear.Add_Click({
    $n = Get-CacheCount
    $r = [Windows.Forms.MessageBox]::Show("将删除缓存 $n 个。`n原图不会被动，确定吗？", '清空缓存', 'YesNo', 'Question')
    if ($r -eq 'Yes') { $n2 = Clear-Cache; Add-Log "已清理 $n2 个（原图未动）。"; Update-Progress }
})
$btnCopy.Add_Click({ if ($txtUrl.Text) { [Windows.Forms.Clipboard]::SetText($txtUrl.Text); Add-Log '地址已复制。' } })

$listBox.Add_DoubleClick({
    if ($script:mode -ne 'custom') { return }
    if (-not $script:opts.dblclick) { return }
    if ($listBox.SelectedIndex -ge 0) {
        $dirs = @((Read-Cfg).dirs)
        if ($listBox.SelectedIndex -lt $dirs.Count) {
            $p = $dirs[$listBox.SelectedIndex]
            if (Test-Path -LiteralPath $p) { Start-Process explorer.exe $p }
        }
    }
})

$chkEnv.Add_CheckedChanged({ $script:opts.env = $chkEnv.Checked; Save-Cfg (Read-Cfg).dirs $script:mode $script:opts; $lblEnv.Visible = ($script:mode -eq 'detail' -or $script:opts.env) })
$chkDbl.Add_CheckedChanged({ $script:opts.dblclick = $chkDbl.Checked; Save-Cfg (Read-Cfg).dirs $script:mode $script:opts })
$cmbNames.Add_SelectedIndexChanged({
    $script:opts.names = switch ($cmbNames.SelectedIndex) { 0 { 'full' } 2 { 'none' } default { 'short' } }
    Save-Cfg (Read-Cfg).dirs $script:mode $script:opts
    Refresh-List
    Fit-List
    if (Test-Port) { Update-Progress }
})

$form.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } })
$form.Add_DragDrop({
    param($s, $e)
    $items = $e.GetData([Windows.Forms.DataFormats]::FileDrop)
    $dirs = @((Read-Cfg).dirs)
    foreach ($it in $items) { if ((Test-Path -LiteralPath $it -PathType Container) -and -not ($dirs -contains $it)) { $dirs += $it } }
    Save-Cfg $dirs $script:mode $script:opts
    Refresh-List
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2500
$timer.Add_Tick({
    if (-not $script:stopping -and $script:proc -and $script:proc.HasExited -and -not (Test-Port)) {
        Start-Sleep -Milliseconds 400; Start-Service2
    }
    if (-not $script:stopping) { Update-ServerState; if (Test-Port) { Update-Progress } }
})

$script:origColors = @{}

function Get-AvgColor($bmp, $x, $y, $w, $h) {
    $base = [Drawing.Color]::FromArgb(38, 43, 54)
    if (-not $bmp) { return $base }
    try {
        $x = [Math]::Max(0, [int]$x); $y = [Math]::Max(0, [int]$y)
        $w = [Math]::Min([int]$w, $bmp.Width - $x); $h = [Math]::Min([int]$h, $bmp.Height - $y)
        if ($w -le 2 -or $h -le 2) { return $base }
        $r = 0; $g = 0; $b = 0; $n = 0
        for ($i = $x; $i -lt ($x + $w); $i += 6) {
            for ($j = $y; $j -lt ($y + $h); $j += 6) {
                $c = $bmp.GetPixel($i, $j)
                $r += $c.R; $g += $c.G; $b += $c.B; $n++
            }
        }
        if ($n -eq 0) { return $base }
        return [Drawing.Color]::FromArgb([int]($r / $n), [int]($g / $n), [int]($b / $n))
    } catch { return $base }
}

function Blend-Controls {
    $k = 0.5
    foreach ($p in @($panelLeft, $panelRight, $panelOpts)) {
        $bmp = $p.BackgroundImage
        foreach ($c in $p.Controls) {
            try {
                if ($c -is [Windows.Forms.Label]) { $c.BackColor = [Drawing.Color]::Transparent; continue }
                if (-not $script:origColors.ContainsKey($c)) { $script:origColors[$c] = $c.BackColor }
                $kk = $k
                if ($c -eq $listBox) { $kk = 1.0 }
                $base = $script:origColors[$c]
                $avg = Get-AvgColor $bmp $c.Left $c.Top $c.Width $c.Height
                $nr = [int]($base.R * (1 - $kk) + $avg.R * $kk)
                $ng = [int]($base.G * (1 - $kk) + $avg.G * $kk)
                $nb = [int]($base.B * (1 - $kk) + $avg.B * $kk)
                $c.BackColor = [Drawing.Color]::FromArgb($nr, $ng, $nb)
            } catch {}
        }
    }
}
function Update-PanelAlpha {
    if (-not $script:bg) { return }
    $a = [int]$script:opts.alpha
    if ($a -lt 0) { $a = 0 }
    if ($a -gt 100) { $a = 100 }
    $cw = $form.ClientSize.Width; $ch = $form.ClientSize.Height
    $iw = $script:bg.Width; $ih = $script:bg.Height
    $sc = [Math]::Max($cw / $iw, $ch / $ih)
    $dw = $iw * $sc; $dh = $ih * $sc
    $dx = $cw - $dw; $dy = ($ch - $dh) / 2
    $fill = [int](255 * $a / 100)
    foreach ($p in @($panelLeft, $panelRight, $panelOpts)) {
        try {
            if ($p.Width -le 0 -or $p.Height -le 0) { continue }
            $ox = $p.Left; $oy = $p.Top
            if ($p.Parent -ne $form) { $ox = $p.Parent.Left + $p.Left; $oy = $p.Parent.Top + $p.Top }
            $sx = ($ox - $dx) / $sc
            $sy = ($oy - $dy) / $sc
            $sw = $p.Width / $sc
            $sh = $p.Height / $sc
            $bmp = New-Object Drawing.Bitmap($p.Width, $p.Height)
            $g = [Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $dstR = New-Object Drawing.Rectangle(0, 0, $p.Width, $p.Height)
            $g.DrawImage($script:bg, $dstR, [single]$sx, [single]$sy, [single]$sw, [single]$sh, [Drawing.GraphicsUnit]::Pixel)
            $f2 = $fill
            if ($p -eq $panelRight) { $f2 = 45 }
            $ov = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($f2, 38, 43, 54))
            $g.FillRectangle($ov, $dstR)
            $ov.Dispose(); $g.Dispose()
            $p.BackgroundImage = $bmp
            $p.BackgroundImageLayout = 'None'
        } catch {}
    }
}
function Show-Settings {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = '设置'
    $dlg.ClientSize = New-Object Drawing.Size(360, 200)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $card; $dlg.ForeColor = $fg
    $dlg.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9.5)

    $dlg.Controls.Add((New-Label '显示模式' 20 18 120 20 9 $dim))
    $m = New-Object Windows.Forms.ComboBox
    $m.DropDownStyle = 'DropDownList'
    $m.Location = New-Object Drawing.Point(20, 42)
    $m.Size = New-Object Drawing.Size(200, 26)
    [void]$m.Items.AddRange(@('简洁模式', '标准模式', '详细模式', '自定义'))
    $m.SelectedIndex = switch ($script:mode) { 'simple' { 0 } 'detail' { 2 } 'custom' { 3 } default { 1 } }
    $dlg.Controls.Add($m)

    $ok = New-Btn '保存' 150 140 90 34 $accent
    $cancel = New-Btn '取消' 250 140 90 34 ([Drawing.Color]::FromArgb(56, 62, 76))
    $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel)

    $ok.Add_Click({
        $script:mode = switch ($m.SelectedIndex) { 0 { 'simple' } 2 { 'detail' } 3 { 'custom' } default { 'standard' } }
        Save-Cfg (Read-Cfg).dirs $script:mode $script:opts
        $dlg.Close()
        Apply-Mode $script:mode
        $form.Invalidate()
    })
    $cancel.Add_Click({ $dlg.Close() })
    [void]$dlg.ShowDialog($form)
}


$chkBar.Add_CheckedChanged({ $script:opts.bar = $chkBar.Checked; Save-Cfg (Read-Cfg).dirs $script:mode $script:opts; Apply-Mode $script:mode })
$chkPtext.Add_CheckedChanged({ $script:opts.ptext = $chkPtext.Checked; Save-Cfg (Read-Cfg).dirs $script:mode $script:opts; Apply-Mode $script:mode })
$chkConv.Add_CheckedChanged({ $script:opts.convert_heic = $chkConv.Checked; Save-Cfg (Read-Cfg).dirs $script:mode $script:opts })
$chkPurge.Add_CheckedChanged({ $script:opts.purge_now = $chkPurge.Checked; Save-Cfg (Read-Cfg).dirs $script:mode $script:opts })
$tbDim.Add_Scroll({ $script:opts.alpha = [int]$tbDim.Value; Save-Cfg (Read-Cfg).dirs $script:mode $script:opts; Update-PanelAlpha; Blend-Controls })

$btnSettings.Add_Click({ Show-Settings })
try {
    $desk = [Environment]::GetFolderPath('Desktop')
    $lnkp = Join-Path $desk '图片查看器（局域网版本）.lnk'
    $icop = Join-Path $root '图标.ico'
    if (-not (Test-Path -LiteralPath $lnkp) -and (Test-Path -LiteralPath $icop)) {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnkp)
        $s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$root\启动器.ps1`""
        $s.WorkingDirectory = $root
        $s.IconLocation = $icop
        $s.Description = '打开局域网图片查看器'
        $s.Save()
    }
} catch {}

$form.Add_Shown({
    $validNow = @((Read-Cfg).dirs | Where-Object { Test-Path -LiteralPath $_ })
    if ($validNow.Count -eq 0) {
        $dlg0 = New-Object Windows.Forms.FolderBrowserDialog
        $dlg0.Description = '第一次使用：请选一个放图片的文件夹'
        $dlg0.ShowNewFolderButton = $true
        if ($dlg0.ShowDialog() -eq 'OK') {
            Save-Cfg @($dlg0.SelectedPath) $script:mode $script:opts
            Refresh-List
        }
    }    try {
        $marker = Join-Path $root 'firewall_asked.txt'
        if (-not (Test-Path -LiteralPath $marker)) {
            $rule = ((netsh advfirewall firewall show rule name="图片查看器-8765" 2>$null) -join "`n")
            if ($rule -notmatch '图片查看器-8765') {
                $ans = [Windows.Forms.MessageBox]::Show("手机打不开通常是防火墙拦住了。`n现在自动放行吗？（会弹管理员确认框）", '放行防火墙', 'YesNo', 'Question')
                if ($ans -eq 'Yes') {
                    $fw = Join-Path $root '放行防火墙.ps1'
                    if (Test-Path -LiteralPath $fw) {
                        Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$fw`"") -WindowStyle Normal
                    }
                }
            }
            Set-Content -LiteralPath $marker -Value '1' -Encoding ASCII
        }
    } catch {}
    Refresh-List
    $ok = Refresh-Env
    Apply-Mode $script:mode
    Update-ServerState
    $timer.Start()
    if ($ok -and -not (Test-Port)) { Start-Service2 }
})

$form.Add_FormClosing({
    if (Test-Port) {
        $r = [Windows.Forms.MessageBox]::Show("关闭窗口会同时停止服务，手机将无法访问。`n确定关闭吗？", '图片查看器', 'YesNo', 'Question')
        if ($r -ne 'Yes') { $_.Cancel = $true; return }
    }
    $script:stopping = $true
    $timer.Stop()
    if (Test-Port) { Stop-Service2 }
    if ($script:bg) { $script:bg.Dispose() }
})

[void]$form.ShowDialog()
