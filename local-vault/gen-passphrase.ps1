<#
  生成主密码（口令形式）  gen-passphrase.ps1
  ────────────────────────────────────────────────────────────
  用 EFF 的 7776 词表随机挑词，每词约 12.9 位熵；6 词 ≈ 77 位熵。
  熵够、好记、不用记大小写和符号。
  只在本机窗口显示，不写文件、不发网络。

  -NoPause  不等待按键（自动测试用）
#>

[CmdletBinding()]
param([switch]$NoPause)

$ErrorActionPreference = 'Stop'

# 找词表
$candidates = @(
    (Join-Path $PSScriptRoot 'tools\eff_large_wordlist.txt'),
    (Join-Path $PSScriptRoot 'eff_large_wordlist.txt')
)
$listFile = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $listFile) {
    Write-Host '✗ 找不到词表 eff_large_wordlist.txt'
    Write-Host "  应该放在：$PSScriptRoot\tools\eff_large_wordlist.txt"
    Write-Host ''
    if (-not $NoPause) { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    exit 1
}

$words = @(Get-Content -LiteralPath $listFile | Where-Object { $_.Trim() -ne '' })
if ($words.Count -lt 1000) {
    Write-Host "✗ 词表内容异常（只有 $($words.Count) 个词）"
    if (-not $NoPause) { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    exit 1
}

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
function Get-RandomIndex([int]$max) {
    $buf = New-Object byte[] 4
    $rng.GetBytes($buf)
    $n = [System.BitConverter]::ToUInt32($buf, 0)
    return [int]($n % $max)
}

$wordCount = 6
$entropyPerWord = [math]::Log($words.Count, 2)
$totalEntropy = [math]::Round($entropyPerWord * $wordCount, 1)

Write-Host ''
Write-Host '================================================================'
Write-Host '  主密码候选（口令形式）'
Write-Host '================================================================'
Write-Host ("  词表 {0} 个词 · 每词 {1:N1} 位熵 · {2} 个词 ≈ {3} 位熵" -f $words.Count, $entropyPerWord, $wordCount, $totalEntropy)
Write-Host ''

for ($i = 1; $i -le 3; $i++) {
    $picked = @()
    while ($picked.Count -lt $wordCount) {
        $w = $words[(Get-RandomIndex $words.Count)]
        if ($picked -notcontains $w) { $picked += $w }
    }
    Write-Host ("   第 {0} 个：  {1}" -f $i, ($picked -join '-'))
    Write-Host ''
}

Write-Host '----------------------------------------------------------------'
Write-Host '  怎么用：'
Write-Host '   1. 挑一个你读两遍就记得住的（读音顺口比"看起来随机"更重要）'
Write-Host '   2. 抄在纸上，纸和 U 盘分开存放'
Write-Host '   3. 不要截图、不要发微信、不要存进任何网盘或笔记软件'
Write-Host '   4. 大小写随意，但以后每次都要一样——建议全部小写，只记词和连字符'
Write-Host '----------------------------------------------------------------'
Write-Host ''
if (-not $NoPause) {
    Write-Host '按任意键关闭（窗口关掉后这串字就没了）...'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
