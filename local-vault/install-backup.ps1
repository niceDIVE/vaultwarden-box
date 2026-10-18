<#
  一次性安装  install-backup.ps1
  ────────────────────────────────────────────────────────────
  做四件事：
    1. 把 kdbx-backup.ps1 复制到 %LOCALAPPDATA%\kdbx-backup\（这个位置不用管理员权限）
    2. 注册计划任务 kdbx-backup，每天 12:00 跑一次
    3. 立刻试跑一次，把结果显示在屏幕上
    4. 打印"下一步该看什么"

  加 -DryRun 只打印、不真的复制和注册（演练用）。

  卸载：命令行执行  schtasks /Delete /TN kdbx-backup /F
#>

[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$here       = $PSScriptRoot
$srcScript  = Join-Path $here 'kdbx-backup.ps1'
$srcPathCfg = Join-Path $here 'kdbx-path.txt'
$installDir = Join-Path $env:LOCALAPPDATA 'kdbx-backup'
$instScript = Join-Path $installDir 'kdbx-backup.ps1'
$taskName   = 'kdbx-backup'
$runTime    = '12:00'

function Say([string]$m) { Write-Host $m }

Say '=========================================='
Say ' 密码库每日备份 · 安装程序'
Say '=========================================='
if ($DryRun) { Say '【演练模式】只打印、不真的改动系统。' }
Say ''

# ── 0. 前置检查 ──────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $srcScript)) {
    Say "✗ 找不到 kdbx-backup.ps1。请确认这个安装程序与它放在同一个文件夹里："
    Say "  $here"
    Say ''
    Say '按任意键关闭...'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}
Say "✓ 找到备份脚本：$srcScript"

# ── 1. 复制到 LOCALAPPDATA ───────────────────────────────────
if ($DryRun) {
    Say "[演练] 将创建目录：$installDir"
    Say "[演练] 将复制：$srcScript → $instScript"
} else {
    if (-not (Test-Path -LiteralPath $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $srcScript -Destination $instScript -Force
    Say "✓ 已安装到：$instScript"
}
if (Test-Path -LiteralPath $srcPathCfg) {
    if ($DryRun) { Say "[演练] 将复制路径配置：$srcPathCfg" }
    else {
        Copy-Item -LiteralPath $srcPathCfg -Destination (Join-Path $installDir 'kdbx-path.txt') -Force
        Say '✓ 已复制 kdbx-path.txt（自定义密码库路径）'
    }
}

# ── 2. 注册计划任务 ─────────────────────────────────────────
$argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $instScript

if ($DryRun) {
    Say "[演练] 将注册计划任务 $taskName，每天 $runTime 运行："
    Say "        powershell.exe $argLine"
} else {
    # 不单独调用 Unregister：Register 的 -Force 会覆盖同名任务，
    # 而 Unregister 一旦因权限或模块问题抛错，会打断整个安装流程。
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Say '（检测到同名任务，将被覆盖）'
    }

    try {
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
        $trigger = New-ScheduledTaskTrigger -Daily -At $runTime
        $principal = New-ScheduledTaskPrincipal `
            -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
            -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Description '密码库每日备份（KeePassXC）' -Force | Out-Null
        Say "✓ 已注册计划任务：每天 $runTime 自动备份"
    }
    catch {
        Say "✗ 注册计划任务失败：$($_.Exception.Message)"
        Say '  改用 schtasks 再试一次...'
        $cmd = 'schtasks /Create /F /SC DAILY /ST {0} /TN {1} /TR "powershell.exe {2}" /RU "{3}\{4}" /IT /RL LIMITED' -f `
               $runTime, $taskName, $argLine.Replace('"', '\"'), $env:USERDOMAIN, $env:USERNAME
        cmd.exe /c $cmd
        if ($LASTEXITCODE -ne 0) {
            Say '✗ 两种方式都没成功。请把上面这行错误截图发给助手。'
            Say '按任意键关闭...'
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            exit 1
        }
        Say '✓ 已用 schtasks 注册成功'
    }
}

# ── 3. 立刻试跑一次 ─────────────────────────────────────────
Say ''
Say '──────────────── 试跑一次备份 ────────────────'
if ($DryRun) {
    Say "[演练] 将执行：powershell -File `"$instScript`""
    Say '[演练] 结束。真的运行时这里会显示备份结果。'
    exit 0
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $instScript
$code = $LASTEXITCODE

Say ''
if ($code -eq 0) {
    Say '✓ 试跑成功。备份文件在 D:\kdbx-backup\，日志在同目录 backup-log.txt。'
} else {
    Say "✗ 试跑失败（退出码 $code）。日志在 D:\kdbx-backup\backup-log.txt"
    Say ''
    Say '最常见的两个原因：'
    Say '  1. 还没建密码库，或路径不是默认位置'
    Say '     → 在记事本里新建 kdbx-path.txt，第一行写密码库完整路径，'
    Say "        存到 $installDir\ 里，然后重新双击本安装程序。"
    Say '  2. 坚果云还没把文件同步到本机（文件是"占位"状态）'
    Say '     → 在坚果云里对该文件点"下载/始终保留"，等它变成本地真实文件。'
}

Say ''
Say '按任意键关闭...'
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
exit $code
