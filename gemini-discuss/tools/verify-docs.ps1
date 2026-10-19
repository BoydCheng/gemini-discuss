#!/usr/bin/env pwsh
<#
.SYNOPSIS
  gemini_qa 文档体检（离线，只读）：比对文档标记 / state / 实际段落，排查残缺与重复提问。
.DESCRIPTION
  背景：Gemini 端的“盲重试”曾造成同一问题被重复发送 3 次并全部写入文档（2026-10-15 侦察事故）。
  本工具不碰浏览器，检查项：
    1. 标记完整性：<!-- gemini-discuss: ... --> 是否存在、rounds 与实际 ## Q 段数是否一致
    2. 重复提问：相邻（或任意）两段的 **Q:** 文本几乎相同 → 疑似盲重试重复
    3. state 交叉核对：convUrl 是否一致、state.rounds 是否一致
.PARAMETER Roots
  要扫描的根目录，默认 D:\MyProjects
.PARAMETER Only
  只处理路径匹配该通配符的文档（调试用），默认全部
.EXAMPLE
  pwsh -File verify-docs.ps1 -Roots D:\MyProjects
#>
param(
  [string[]]$Roots = @('D:\MyProjects'),
  [string]$Only = "*"
)

$ErrorActionPreference = "Continue"
$STATE_DIR = if ($env:GEMINI_DISCUSS_STATE) { $env:GEMINI_DISCUSS_STATE } else { Join-Path $env:LOCALAPPDATA "gemini-discuss\state" }
$META_RE = '<!--\s*gemini-discuss:\s*([^>]*?)-->'

function Read-Text { param([string]$Path) if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } return $null }
function Get-DocMarker {
  param([string]$Path)
  $txt = Read-Text $Path
  if (-not $txt) { return $null }
  $m = [regex]::Match($txt, $META_RE)
  if (-not $m.Success) { return $null }
  $out = @{}
  foreach ($kv in ($m.Groups[1].Value -split '\s+')) {
    if ($kv -match '^([^=]+)=(.*)$') { $out[$matches[1]] = $matches[2] }
  }
  return $out
}
function Normalize-Text {
  param([string]$T)
  if (-not $T) { return "" }
  $s = [regex]::Replace($T, '\s+', '')
  return ($s -replace '[*_`~#]', '')
}
function Get-States {
  $map = @{}
  if (Test-Path $STATE_DIR) {
    foreach ($f in (Get-ChildItem $STATE_DIR -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
      $raw = Read-Text $f.FullName
      if (-not $raw) { continue }
      try { $o = $raw | ConvertFrom-Json; if ($o.session) { $map[$o.session] = $o } } catch {}
    }
  }
  return $map
}

Write-Host ""
Write-Host "=== 扫描文档 ===" -ForegroundColor Cyan
$docs = New-Object System.Collections.Generic.List[object]
foreach ($root in $Roots) {
  if (-not (Test-Path $root)) { continue }
  Get-ChildItem -Path $root -Recurse -Directory -Filter 'gemini_qa' -ErrorAction SilentlyContinue | ForEach-Object {
    Get-ChildItem -Path $_.FullName -File -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.FullName -notlike $Only) { return }
      $txt = Read-Text $_.FullName
      $mk = [regex]::Match($txt, $META_RE)
      $hasMarker = $mk.Success
      $conv = $null
      if ($hasMarker) {
        $cm = [regex]::Match($mk.Groups[1].Value, 'conv=(\S+)')
        if ($cm.Success) { $conv = $cm.Groups[1].Value }
      } else {
        $lm = [regex]::Match($txt.Substring(0, [Math]::Min(3000, $txt.Length)), 'gemini\.google\.com/(?:u/\d+/)?app/([0-9a-f]{8,})')
        if ($lm.Success) { $conv = "https://gemini.google.com/app/" + $lm.Groups[1].Value }
      }
      [void]$docs.Add([pscustomobject]@{ Path = $_.FullName; Name = $_.Name; Text = $txt; Marker = $hasMarker; Conv = $conv })
    }
  }
}
Write-Host ("  找到 " + $docs.Count + " 份 gemini_qa 文档")
if ($docs.Count -eq 0) { Write-Host "（没有可体检的文档）"; exit 0 }

$states = Get-States
$verdicts = New-Object System.Collections.Generic.List[object]
foreach ($doc in $docs) {
  $problems = New-Object System.Collections.Generic.List[string]
  $blocks = [regex]::Matches($doc.Text, '(?ms)^##\s*Q(\d+).*?(?=^##\s*Q\d+|\z)')
  $marker = Get-DocMarker $doc.Path
  $declaredRounds = $null
  if ($marker -and $marker['rounds']) { $declaredRounds = [int]$marker['rounds'] }
  if ($declaredRounds -ne $null -and $declaredRounds -ne $blocks.Count) {
    [void]$problems.Add("标记 rounds=$declaredRounds 与实际段落数=$($blocks.Count) 不一致")
  }
  if (-not $doc.Marker) { [void]$problems.Add("缺 gemini-discuss 标记（旧格式或手写文档）") }

  # 重复提问检测
  $qs = @()
  foreach ($b in $blocks) {
    $qm = [regex]::Match($b.Value, '(?s)\*\*Q:?\*\*\s*(.*?)\s*\*\*A:?\*\*')
    if ($qm.Success) { $qs += ,(Normalize-Text $qm.Groups[1].Value) }
  }
  for ($i = 1; $i -lt $qs.Count; $i++) {
    if ($qs[$i].Length -ge 10 -and $qs[$i] -eq $qs[$i - 1]) {
      [void]$problems.Add("Q$($i+1) 与 Q$i 提问文本相同（疑似盲重试重复提问）")
    }
  }

  # state 核对
  if ($marker -and $marker['session'] -and $states.ContainsKey($marker['session'])) {
    $st = $states[$marker['session']]
    if ($st.convUrl -and $doc.Conv -and $st.convUrl -ne $doc.Conv) { [void]$problems.Add("state.convUrl 与文档链接不一致: $($st.convUrl)") }
    if ($null -ne $st.rounds -and [int]$st.rounds -ne $blocks.Count) { [void]$problems.Add("state.rounds=$($st.rounds) 与段落数=$($blocks.Count) 不一致") }
  } else {
    [void]$problems.Add("无对应 state（session 缺失或未记录）")
  }

  [void]$verdicts.Add([pscustomobject]@{ 文档 = $doc.Name; 段数 = $blocks.Count; 标记 = $(if ($doc.Marker) { "有" } else { "无" }); 问题数 = $problems.Count; 问题 = ($problems -join "；") })
  foreach ($p in $problems) { Write-Host ("    " + $doc.Name.PadRight(40) + " " + $p) -ForegroundColor $(if ($p -match '盲重试') { "Red" } else { "Yellow" }) }
}

Write-Host ""
Write-Host "=== 汇总 ===" -ForegroundColor Cyan
$verdicts | Sort-Object 问题数 -Descending | Format-Table -AutoSize
$bad = @($verdicts | Where-Object { $_.问题数 -gt 0 }).Count
Write-Host ("文档 " + $verdicts.Count + " 份；有问题的 " + $bad + " 份") -ForegroundColor $(if ($bad -gt 0) { "Yellow" } else { "Green" })
Write-Host "（本工具只读，未修改任何文件）" -ForegroundColor DarkGray
exit 0
