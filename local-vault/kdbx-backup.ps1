<#
  密码库每日备份  kdbx-backup.ps1
  ────────────────────────────────────────────────────────────
  作用：把 KeePassXC 的密码库复制一份带日期的副本到本地备份盘，只保留最近 $Keep 份。
  由 Windows 计划任务每天 12:00 自动运行；也可以手动跑。

  它做了三件比"直接复制"更严的事：
    1. 先复制成 .part 临时文件，校验通过才改名 → 断电/失败不会留下"看起来像备份"的半截文件
    2. 比对源文件与副本的 SHA-256 → 复制过程出错会被发现
    3. 检查文件头魔数（KDBX3/KDBX4）→ 抓出网盘"占位文件"、0 字节文件、没下载完的文件

  出错时：写日志、以退出码 1 结束，且绝不删除任何旧备份。

  可调参数：
    -Source  密码库完整路径（不填则自动查找，见下方候选路径）
    -Dest    备份目录，默认 D:\kdbx-backup
    -Keep    保留份数，默认 30
#>

[CmdletBinding()]
param(
    [string]$Source = '',
    [string]$Dest   = 'D:\kdbx-backup',
    [int]$Keep      = 30
)

# 不用全局 Stop：我们要自己接住每一步的错误并写日志
$ErrorActionPreference = 'Continue'

# ── 准备目录与日志 ───────────────────────────────────────────
try {
    if (-not (Test-Path -LiteralPath $Dest)) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }
} catch {
    Write-Host "无法创建备份目录 $Dest ：$($_.Exception.Message)"
    exit 1
}

$LogFile = Join-Path $Dest 'backup-log.txt'

function Write-Log {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

# 日志超过 512KB 时，只保留最后 200 行，避免无限增长
try {
    if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 512KB)) {
        $tail = Get-Content -LiteralPath $LogFile -Tail 200
        Set-Content -LiteralPath $LogFile -Value $tail -Encoding UTF8
    }
} catch { }

# ── 定位密码库文件 ───────────────────────────────────────────
if (-not $Source) {
    # 1) 同目录下的 kdbx-path.txt（第一行写完整路径），路径变了只改这个文本文件
    $cfg = Join-Path $PSScriptRoot 'kdbx-path.txt'
    if (Test-Path -LiteralPath $cfg) {
        $first = Get-Content -LiteralPath $cfg -TotalCount 1 -ErrorAction SilentlyContinue
        if ($first) { $Source = $first.Trim().Trim('"').Trim("'") }
    }
}

if (-not $Source) {
    # 2) 常见位置：坚果云同步文件夹 / OneDrive
    $candidates = @()
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE 'Nutstore\我的坚果云\Passwords\main.kdbx')
        $candidates += (Join-Path $env:USERPROFILE 'Nutstore\Passwords\main.kdbx')
        $candidates += (Join-Path $env:USERPROFILE '坚果云\我的坚果云\Passwords\main.kdbx')
        $candidates += (Join-Path $env:USERPROFILE 'Documents\Passwords\main.kdbx')
    }
    if ($env:OneDrive) {
        $candidates += (Join-Path $env:OneDrive 'Passwords\main.kdbx')
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { $Source = $c; break }
    }
}

if (-not $Source) {
    Write-Log '失败：找不到密码库文件。请把完整路径写进脚本同目录的 kdbx-path.txt（一行，例如 C:\Users\WANG\Nutstore\我的坚果云\Passwords\main.kdbx）'
    exit 1
}

$Source = $Source.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    Write-Log "失败：密码库文件不存在 → $Source"
    exit 1
}

# ── 复制 + 三重校验 ──────────────────────────────────────────
$stamp       = (Get-Date).ToString('yyyyMMdd')
$baseName    = [System.IO.Path]::GetFileNameWithoutExtension($Source)   # main
$targetName  = "$baseName-$stamp.kdbx"                                  # main-20261018.kdbx
$targetPath  = Join-Path $Dest $targetName
$tempPath    = "$targetPath.part"
$sourceSize  = (Get-Item -LiteralPath $Source).Length

if ($sourceSize -lt 100) {
    Write-Log "失败：源文件只有 $sourceSize 字节，明显不是完整密码库（可能是网盘占位文件）→ $Source"
    exit 1
}

try {
    Copy-Item -LiteralPath $Source -Destination $tempPath -Force -ErrorAction Stop

    $h1 = (Get-FileHash -LiteralPath $Source   -Algorithm SHA256 -ErrorAction Stop).Hash
    $h2 = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($h1 -ne $h2) { throw "复制后 SHA-256 不一致（源 $h1 / 副本 $h2）" }

    # 文件头魔数：KDBX4 = 03D9A29A67FB4BB5，KDBX3 = 9AA2D903B54FB667
    $fs = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    try {
        $head = New-Object byte[] 8
        $read = $fs.Read($head, 0, 8)
    } finally {
        $fs.Close()
    }
    if ($read -lt 8) { throw '备份文件不足 8 字节，读取失败' }
    $hex = -join ($head | ForEach-Object { $_.ToString('x2') })
    if ($hex -ne '03d9a29a67fb4bb5' -and $hex -ne '9aa2d903b54fb667') {
        throw "文件头不是 KDBX 格式（实际 $hex）→ 可能是网盘占位文件或没下载完"
    }

    Move-Item -LiteralPath $tempPath -Destination $targetPath -Force -ErrorAction Stop
    Write-Log ("成功：{0}（{1:N0} 字节，SHA-256 {2}…）" -f $targetName, $sourceSize, $h1.Substring(0, 12))
}
catch {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
    Write-Log "失败：$($_.Exception.Message)"
    exit 1
}

# ── 只保留最近 $Keep 份 ──────────────────────────────────────
try {
    $all    = Get-ChildItem -LiteralPath $Dest -File -ErrorAction Stop |
              Where-Object { $_.Extension -eq '.kdbx' } |
              Sort-Object Name -Descending    # 文件名含 yyyyMMdd，按名倒序 = 按日期倒序
    $extra  = @($all | Select-Object -Skip $Keep)
    foreach ($f in $extra) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        Write-Log "清理旧备份：$($f.Name)"
    }
    # 删除后重新统计，避免日志报出已经删掉的文件名
    $left = @(Get-ChildItem -LiteralPath $Dest -File -ErrorAction Stop |
              Where-Object { $_.Extension -eq '.kdbx' } |
              Sort-Object Name)
    if ($left.Count -gt 0) {
        Write-Log ("当前保留 {0} 份，最旧 {1}，最新 {2}" -f $left.Count, $left[0].Name, $left[$left.Count - 1].Name)
    } else {
        Write-Log '当前保留 0 份'
    }
}
catch {
    # 清理失败不影响备份本身已经成功这件事
    Write-Log "警告：清理旧备份时出错 → $($_.Exception.Message)"
}

exit 0
