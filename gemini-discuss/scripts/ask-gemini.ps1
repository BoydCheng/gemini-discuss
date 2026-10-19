#!/usr/bin/env pwsh
<#
.SYNOPSIS
  与网页版 Gemini 完成一轮问答（真实浏览器 via Kimi WebBridge）。v1（2026-10-15 首版）
.DESCRIPTION
  连续性设计（与 chatgpt-discuss 相同的身份模型）:
    * 一个讨论的唯一身份 = Gemini 会话 URL https://gemini.google.com/u/<N>/app/<id>
      —— 持久化在 state\<session>.json，并回写进文档头的 gemini-discuss 注释。
    * 浏览器标签组（webbridge session）只是执行通道：标签丢了拿 convUrl 重开即可。
    * -New 幂等：锚点已存在时拒绝新建（exit 10），确认要开新线程必须显式 -ForceNew。
    * 发送前硬校验 location.href 必须属于锚定会话（exit 11）。
    * 文档头由本脚本写（含链接/账号/模式），不需要也不允许 AI 手写。

  Gemini 特有交互层（本机实测结论，详见 notes\2026-10-15-recon.md）:
    * 多账号：用 /u/<N>/ 路径区分。-Account 留空时自动检测浏览器当前登录账号；
   指定邮箱时首次自动扫描索引（并兜底默认账号页）。
    * 页面必须在“可见”状态下加载/交互：窗口被后台化时输入区不注册输入、会话不渲染。
      → 强制激活（minimize+restore+SetForegroundWindow + CDP Page.bringToFront）
    * 发送闸门：fill 后必须等 button[aria-label="发送"] 出现才按 Enter；
      发送结果用 user-query 数量核实，绝不盲重试（避免重复提问）。
    * 模式选择器（模型/思考等级）只认键盘导航（roving tabindex：
      ArrowDown/Up + ArrowRight 进子菜单 + Enter 提交）；鼠标点击菜单项无效。
    * 答案读取 = DOM→Markdown 重建（表格/代码块/列表/加粗保真），完成判定 =
      新 model-response + 文本长度稳定 + stop 按钮消失。
.PARAMETER Question
  要问的问题（支持中文）。
.PARAMETER Session
  讨论标识（slug）。不传时: 有 -DocPath 就从文档名推导；否则复用当前工作区最近用过的讨论。
.PARAMETER DocPath
  Q&A 追加写入的 Markdown 文档。不传时: 优先复用该 session 已记录的文档（跨天不拆文件）。
.PARAMETER Title
  文档标题（仅首轮写入）。
.PARAMETER GroupTitle
  浏览器标签组显示名（仅建组时生效）。
.PARAMETER ConvUrl
  显式指定要锚定的已有会话（https://gemini.google.com/u/<N>/app/<id>）。恢复/接管时用。
.PARAMETER New
  声明“这是一个新讨论线程”。若该 session 已有锚点 → 拒绝（exit 10）。不加也能正常跑。
.PARAMETER ForceNew
  确认要放弃原线程、开一个新的（旧链接进 history 归档）。
.PARAMETER Status
  只读列出所有已记录的讨论（不碰浏览器、不加锁）后退出。
.PARAMETER CloseExtras
  关闭该 session 内所有“不属于本讨论”的 gemini.google.com 标签。
.PARAMETER NoDedupe
  保留（当前仅影响提示行为）。
.PARAMETER TimeoutSec
  单轮生成超时（秒），默认 600。
.PARAMETER MaxRecover
  单轮内“标签丢失用 convUrl 重开”的最大次数，默认 2。
.PARAMETER Daemon
  webbridge daemon 地址。留空 = 自动探测（daemon.addr → 默认 http://127.0.0.1:10086）。
.PARAMETER ListChats
  只读：列出 Gemini 账号里的会话（标题 / 会话 id / 本地锚定情况）。不提问、不改文档。
.PARAMETER Attach
  把“已存在的会话”挂到当前讨论：给标题关键字（模糊匹配）或直接给 /app/<id>。
  配合 -Session/-DocPath 使用；不带 -Question 时只做绑定不发问。
.PARAMETER Limit
  -ListChats 显示多少条，默认 30。
.PARAMETER Account
  目标 Google 账号 email。留空 = 自动检测浏览器当前登录的 Gemini 账号。
.PARAMETER Model
  首选模型（菜单标签，如 "4 Argon"）。缺失时按脚本内置偏好列表自动降级。
.PARAMETER Thinking
  首选思考等级（菜单标签，如 "高点"、"Deep Think"）。缺失时自动降级。
.EXITCODES
   0  成功
   3  webbridge daemon 不可用
   5  Gemini 页面未就绪（登录墙/加载失败/改版）
   6  有锚点却既拿不到标签、也打不开会话页
   7  填入问题失败（fill 成功但发送键闸门超时）
   8  发送失败（已核实：会话里没有新提问）
   9  生成超时且无可用回答
  10  拒绝新建：该 session 已有讨论线程（要开新线程请加 -ForceNew）
  11  发送前校验失败：当前页面不是锚定会话
  12  同一 session 已有另一个 ask-gemini 进程在跑
  13  参数/文档冲突
  14  目标账号未就绪（浏览器里找不到 -Account 指定的 Google 账号）
.EXAMPLE
  pwsh -File ask-gemini.ps1 -Question "请介绍Modbus" -Session modbus-101 -New -Title "Modbus 入门"
.EXAMPLE
  pwsh -File ask-gemini.ps1 -Question "那 CRC 呢？" -Session modbus-101
.EXAMPLE
  pwsh -File ask-gemini.ps1 -Status
#>
param(
  [string]$Question = "",
  [string]$Session = "",
  [string]$DocPath = "",
  [string]$Title = "",
  [string]$GroupTitle = "",
  [string]$ConvUrl = "",
  [switch]$New,
  [switch]$ForceNew,
  [switch]$Status,
  [switch]$CloseExtras,
  [switch]$NoDedupe,
  [int]$TimeoutSec = 600,
  [int]$MaxRecover = 2,
  [string]$Daemon = "",
  [switch]$ListChats,
  [string]$Attach = "",
  [int]$Limit = 30,
  [string]$Account = "",
  [string]$Model = "4 Argon",
  [string]$Thinking = "高点"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$GEMINI_HOST = "gemini.google.com"
$SKILL_DIR  = Split-Path $PSScriptRoot -Parent
$STATE_DIR  = if ($env:GEMINI_DISCUSS_STATE) { $env:GEMINI_DISCUSS_STATE } else { Join-Path $env:LOCALAPPDATA "gemini-discuss\state" }

# 偏好列表：第一项给 -Model/-Thinking 参数覆盖；其余为自动降级顺序（越靠前越“深”）
$MODEL_PREF    = @($Model, "4 Argon", "3.1 Pro", "3.8 Flash", "3.5 Flash-Lite") | Select-Object -Unique
$THINKING_PREF = @($Thinking, "Deep Think", "高点", "中等", "低点") | Select-Object -Unique

# ============================ 基础设施 ============================

function Ensure-Dir { param([string]$Path) if ($Path -and -not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Write-Utf8 { param([string]$Path, [string]$Text) Ensure-Dir (Split-Path $Path -Parent); [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }
function Read-Text { param([string]$Path) if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } return $null }

$script:LockSession = $null
function Release-Lock {
  if ($script:LockSession) {
    Remove-Item (Join-Path $STATE_DIR "$($script:LockSession).lock") -Force -ErrorAction SilentlyContinue
    $script:LockSession = $null
  }
}
function Fail {
  param([int]$Code, [string]$Message)
  [Console]::Error.WriteLine("ERROR[$Code] $Message")
  Release-Lock
  exit $Code
}

function Get-ConvId {
  param([string]$Url)
  if (-not $Url) { return $null }
  $m = [regex]::Match($Url, 'gemini\.google\.com/(?:u/\d+/)?app/([0-9a-f]{8,})')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}
function Get-CanonicalConvUrl {
  param([string]$Url, [int]$AcctIndex = -1)
  $id = Get-ConvId $Url
  if (-not $id) { return $null }
  $n = $AcctIndex
  if ($n -lt 0) {
    $m = [regex]::Match($Url, 'gemini\.google\.com/u/(\d+)/app/')
    if ($m.Success) { $n = [int]$m.Groups[1].Value }
  }
  if ($n -lt 0) { return "https://$GEMINI_HOST/app/$id" }
  return "https://$GEMINI_HOST/u/$n/app/$id"
}
function Get-HomeUrl {
  param([int]$AcctIndex = -1)
  if ($AcctIndex -lt 0) { return "https://$GEMINI_HOST/app" }
  return "https://$GEMINI_HOST/u/$AcctIndex/app"
}

# ============================ 状态（SSOT） ============================

function Get-StatePath { param([string]$S) Join-Path $STATE_DIR "$S.json" }
function Read-DiscussState {
  param([string]$S)
  $raw = Read-Text (Get-StatePath $S)
  if (-not $raw) { return $null }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
function Write-DiscussState {
  param([string]$S, $Obj)
  Ensure-Dir $STATE_DIR
  Write-Utf8 (Get-StatePath $S) ($Obj | ConvertTo-Json -Depth 8)
}
function Get-AllStates {
  if (-not (Test-Path $STATE_DIR)) { return @() }
  $out = @()
  foreach ($f in (Get-ChildItem $STATE_DIR -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
    $raw = Read-Text $f.FullName
    if (-not $raw) { continue }
    try { $out += ($raw | ConvertFrom-Json) } catch { Write-Warning "state 文件解析失败，已跳过: $($f.Name)" }
  }
  return $out
}
function Acquire-Lock {
  param([string]$S)
  Ensure-Dir $STATE_DIR
  $p = Join-Path $STATE_DIR "$S.lock"
  if (Test-Path $p) {
    $info = $null
    try { $info = (Read-Text $p) | ConvertFrom-Json } catch {}
    $stale = $true
    if ($info -and $info.pid) {
      $alive = $false
      try { $alive = [bool](Get-Process -Id ([int]$info.pid) -ErrorAction Stop) } catch { $alive = $false }
      $ageMin = 999
      try { $ageMin = ((Get-Date) - ([datetime]$info.time)).TotalMinutes } catch {}
      if ($alive -and $ageMin -lt 30) { $stale = $false }
    }
    if (-not $stale) { return $false }
    Write-Warning "发现陈旧锁文件（持有进程已退出），清理后继续"
    Remove-Item $p -Force -ErrorAction SilentlyContinue
  }
  Write-Utf8 $p (@{ pid = $PID; time = (Get-Date).ToString("o"); session = $S } | ConvertTo-Json -Compress)
  $script:LockSession = $S
  return $true
}

# ============================ 文档 ============================

$META_RE = '<!--\s*gemini-discuss:\s*([^>]*?)-->'
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
function Get-DocRoundCount {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return 0 }
  return (Select-String -Path $Path -Pattern '^## Q\d+' -ErrorAction SilentlyContinue | Measure-Object).Count
}
function Write-DocHeader {
  param([string]$Path, [string]$DocTitle, [string]$S, [string]$Curl, [string]$Acct, [string]$Mode)
  $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $h = @()
  $h += "# Gemini 讨论：$DocTitle（$(Get-Date -Format yyyy-MM-dd)）"
  $h += ""
  $h += "<!-- gemini-discuss: session=$S conv=$Curl account=$Acct mode=$Mode created=$now updated=$now rounds=0 -->"
  $h += "- 会话: $S | 账号: $Acct | 模式: $Mode | 链接: $Curl"
  $h += ""
  Write-Utf8 $Path ($h -join "`r`n")
}
function Update-DocMarker {
  param([string]$Path, [string]$S, [string]$Curl, [string]$Acct, [string]$Mode, [int]$Rounds)
  $txt = Read-Text $Path
  if (-not $txt) { return }
  $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $newMarker = '<!-- gemini-discuss: session=' + $S + ' conv=' + $Curl + ' account=' + $Acct + ' mode=' + $Mode + ' updated=' + $now + ' rounds=' + $Rounds + ' -->'
  if ([regex]::IsMatch($txt, $META_RE)) {
    $txt = $txt -replace $META_RE, $newMarker
  } else {
    $lines = $txt -split "`r?`n"
    $head = @($lines[0], "", $newMarker)
    $txt = ($head + ($lines | Select-Object -Skip 1)) -join "`r`n"
  }
  $txt = [regex]::Replace($txt, '(?m)^- 会话: .*$', ("- 会话: $S | 账号: $Acct | 模式: $Mode | 链接: $Curl"))
  Write-Utf8 $Path $txt
}

# ============================ webbridge ============================

function Resolve-DaemonAddr {
  $p = Join-Path $env:USERPROFILE ".kimi-webbridge\daemon.addr"
  $raw = Read-Text $p
  if ($raw) {
    $a = $raw.Trim()
    if ($a -match '^[A-Za-z0-9\.\-]+:\d+$') { return "http://$a" }
  }
  return "http://127.0.0.1:10086"
}
function Get-DaemonStatus {
  param([string]$Base, [int]$Attempts = 6)
  for ($i = 1; $i -le $Attempts; $i++) {
    $raw = $null
    try { $raw = (& curl.exe -s --noproxy "*" --max-time 6 "$Base/status" 2>$null) } catch {}
    if ($raw) { try { $o = $raw | ConvertFrom-Json; if ($o -and $o.running) { return $o } } catch {} }
    if ($i -lt $Attempts) { Start-Sleep -Milliseconds (300 * $i) }
  }
  return $null
}
function Get-DaemonDiag {
  param([string]$Base)
  $u = [Uri]$Base
  $tcp = "closed"
  try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect($u.Host, $u.Port); $tcp = "open"; $c.Close() } catch { $tcp = "closed" }
  $raw = ""
  try { $raw = ((& curl.exe -s -S --noproxy "*" --max-time 6 "$Base/status" 2>&1) | Select-Object -First 2) -join " | " } catch {}
  return ("webbridge daemon 不可用（$Base）。TCP $($u.Host):$($u.Port)=$tcp。curl 说: $raw  " +
          "先跑: `"$env:USERPROFILE\.kimi-webbridge\bin\kimi-webbridge.exe`" start")
}
function Connect-Daemon {
  if (-not $script:Daemon) {
    $script:Daemon = Resolve-DaemonAddr
    Write-Warning "未指定 -Daemon，自动探测到: $($script:Daemon)"
  }
  $ds = Get-DaemonStatus -Base $script:Daemon -Attempts 6
  if (-not $ds) {
    $bin = Join-Path $env:USERPROFILE ".kimi-webbridge\bin\kimi-webbridge.exe"
    if (Test-Path $bin) {
      Write-Warning "daemon 连续 6 次探测不通，尝试启动..."
      try { & $bin start 2>&1 | Out-Null } catch {}
      Start-Sleep -Seconds 4
      $ds = Get-DaemonStatus -Base $script:Daemon -Attempts 6
    }
    if (-not $ds) { Fail 3 (Get-DaemonDiag -Base $script:Daemon) }
  }
  if (-not $ds.extension_connected) { Write-Warning "扩展未连接，仍尝试执行" }
}

function Invoke-WB {
  param([string]$Action, [hashtable]$WBArgs, [string]$SessionName)
  $body = @{ action = $Action; args = $WBArgs; session = $SessionName } | ConvertTo-Json -Depth 12 -Compress
  $tmp = Join-Path $env:TEMP ("wb-req-" + [guid]::NewGuid().ToString("N") + ".json")
  [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))
  try {
    $raw = & curl.exe -s --noproxy "*" --max-time 180 -X POST "$Daemon/command" -H "Content-Type: application/json" --data-binary "@$tmp" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
    if (-not $raw) { throw "empty response for action $Action" }
    $resp = $raw | ConvertFrom-Json
    if (-not $resp.ok) { throw "webbridge error: $($resp.error.message)" }
    return $resp.data
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function Eval-JS {
  param([string]$Code, [string]$SessionName)
  $d = Invoke-WB "evaluate" @{ code = $Code } $SessionName
  return $d.value
}
function Send-Cdp {
  param([string]$Method, [hashtable]$Params, [string]$SessionName)
  return (Invoke-WB "cdp" @{ method = $Method; params = $Params } $SessionName)
}

# ---------- 浏览器窗口强制激活（Gemini 页面必须可见才能正确加载/交互） ----------

if (-not ("Win32GemAct" -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32GemAct {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
}
"@
}
function Get-BrowserHwnd {
  foreach ($name in @('msedge', 'chrome', 'brave', 'vivaldi')) {
    $procs = Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle }
    foreach ($proc in $procs) { if ($proc.MainWindowTitle -like "*Gemini*") { return $proc.MainWindowHandle } }
  }
  foreach ($name in @('msedge', 'chrome', 'brave', 'vivaldi')) {
    $proc = Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle } | Select-Object -First 1
    if ($proc) { return $proc.MainWindowHandle }
  }
  return [IntPtr]::Zero
}
function Force-ActivateBrowser {
  # 激活策略（按序）：
  #   ① Page.bringToFront（让标签成为窗口活动标签 → 窗口标题含 "Gemini"，便于按标题找到正确窗口）
  #   ② AttachThreadInput 组合拳（绕过 Windows 前台锁——用户正在别的窗口打字时也能抢回前台）
  #   ③ -Nuke 且仍未成功时：最小化+还原 再试
  param([switch]$Nuke, [string]$WbSession = "")
  if (-not $WbSession) { $WbSession = $script:WbSession }
  if ($WbSession) { try { Invoke-WB "cdp" @{ method = "Page.bringToFront"; params = @{} } $WbSession | Out-Null } catch {} }
  Start-Sleep -Milliseconds 350
  $h = Get-BrowserHwnd
  if ($h -eq [IntPtr]::Zero) { return $false }
  if ([Win32GemAct]::IsIconic($h)) { [void][Win32GemAct]::ShowWindow($h, 9); Start-Sleep -Milliseconds 500 }
  $fg = Set-ForegroundViaAttach $h
  if ($Nuke -and -not $fg) {
    [void][Win32GemAct]::ShowWindow($h, 6)
    Start-Sleep -Milliseconds 450
    [void][Win32GemAct]::ShowWindow($h, 9)
    Start-Sleep -Milliseconds 750
    $fg = Set-ForegroundViaAttach $h
  }
  return $fg
}
function Set-ForegroundViaAttach {
  param([IntPtr]$Hwnd)
  try {
    $pid0 = 0
    $fgWnd = [Win32GemAct]::GetForegroundWindow()
    $fgTid = [Win32GemAct]::GetWindowThreadProcessId($fgWnd, [ref]$pid0)
    $curTid = [Win32GemAct]::GetCurrentThreadId()
    if ($fgTid -ne 0 -and $fgTid -ne $curTid) { [void][Win32GemAct]::AttachThreadInput($curTid, $fgTid, $true) }
    [void][Win32GemAct]::BringWindowToTop($Hwnd)
    [void][Win32GemAct]::SetForegroundWindow($Hwnd)
    if ($fgTid -ne 0 -and $fgTid -ne $curTid) { [void][Win32GemAct]::AttachThreadInput($curTid, $fgTid, $false) }
  } catch {}
  Start-Sleep -Milliseconds 350
  return ([Win32GemAct]::GetForegroundWindow() -eq $Hwnd)
}

# ---------- 页面状态 ----------

$JS_STATE = @'
(() => {
  const q = document.querySelector('.ql-editor');
  const ia = document.querySelector('input-area-v2 .input-area') || document.querySelector('.input-area');
  const pk = document.querySelector('button.input-area-switch');
  let email = null;
  for (const e of document.querySelectorAll('[aria-label*="Google"]')) {
    const al = e.getAttribute('aria-label') || '';
    const m = al.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/);
    if (m) { email = m[0]; break; }
  }
  return JSON.stringify({
    url: location.href,
    uq: document.querySelectorAll('user-query').length,
    mr: document.querySelectorAll('model-response').length,
    ed: !!q,
    ready: !!(ia && ia.className.includes('children-ready')),
    send: !!document.querySelector('button[aria-label="发送"]'),
    stop: !!document.querySelector('.stop-button'),
    picker: pk ? (pk.textContent || '').trim().slice(0, 40) : null,
    email: email,
    vis: document.visibilityState,
    focus: document.hasFocus()
  });
})()
'@

function Get-PageState {
  param([string]$SessionName)
  try {
    $v = Eval-JS $JS_STATE $SessionName
    if (-not $v) { return $null }
    return ($v | ConvertFrom-Json)
  } catch { return $null }
}

# ---------- 会话标签管理 ----------

function Get-SessionGeminiTabs {
  param([string]$SessionName)
  try {
    $r = Invoke-WB "list_tabs" @{} $SessionName
    if ($r -and $r.tabs) { return @($r.tabs | Where-Object { $_.url -like "*gemini.google.com/*" }) }
  } catch {}
  return @()
}
function Resolve-ConvTab {
  param([string]$SessionName, [string]$ConvId, [int]$MaxRecover, [string]$Group)
  for ($round = 0; $round -le $MaxRecover; $round++) {
    foreach ($t in (Get-SessionGeminiTabs $SessionName)) {
      if ((Get-ConvId $t.url) -ne $ConvId) { continue }
      try { Invoke-WB "find_tab" @{ url = $t.url } $SessionName | Out-Null } catch { continue }
      try {
        $href = Eval-JS "location.href" $SessionName
        if ((Get-ConvId $href) -eq $ConvId) { return $t }
      } catch {}
    }
    if ($round -lt $MaxRecover) {
      Write-Warning "没有可用的锚定标签，用 convUrl 重开（$($round + 1)/$MaxRecover）"
      try { Invoke-WB "navigate" @{ url = $script:ConvUrl; group_title = $Group } $SessionName | Out-Null } catch {}
      $dl = (Get-Date).AddSeconds(30)
      while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 1500
        try { $h = Eval-JS "location.href" $SessionName; if ((Get-ConvId $h) -eq $ConvId) { return @{ url = $script:ConvUrl; tabId = $null } } } catch {}
      }
    }
  }
  return $null
}
function Close-StrayTabs {
  param([string]$SessionName, [string]$KeepConvId, [int]$Max = 5)
  $n = 0
  foreach ($t in (Get-SessionGeminiTabs $SessionName)) {
    if ($n -ge $Max) { break }
    if ($KeepConvId -and (Get-ConvId $t.url) -eq $KeepConvId) { continue }
    try {
      Invoke-WB "find_tab" @{ url = $t.url } $SessionName | Out-Null
      Invoke-WB "close_tab" @{} $SessionName | Out-Null
      $n++
      Write-Warning ("  清理游离标签: " + $t.url)
    } catch {}
  }
  if ($n -gt 0) { Write-Warning "已清理 $n 个游离标签（本讨论组内非本会话的 gemini 标签）" }
  return $n
}

# ---------- 页面就绪 / 可见重载 ----------

function Wait-PageReady {
  param([string]$SessionName, [int]$Seconds = 30, [int]$ExpectConvId = 0, [int]$MinUq = -1)
  # MinUq >= 0 时要求 user-query 数量达到该值（用于确认会话内容已渲染）
  $deadline = (Get-Date).AddSeconds($Seconds)
  $lastAct = (Get-Date).AddMinutes(-10)
  while ((Get-Date) -lt $deadline) {
    $st = Get-PageState $SessionName
    if ($st) {
      # 就绪 = 编辑器存在 且（输入区 children-ready / 模式选择器在场 / 会话已有消息）
      $ok = $st.ed -and ($st.ready -or $st.picker -or [int]$st.uq -gt 0)
      if ($ok -and $MinUq -ge 0 -and [int]$st.uq -lt $MinUq) { $ok = $false }
      if ($ok) { return $st }
      if (((Get-Date) - $lastAct).TotalSeconds -gt 8 -and ($st.vis -ne 'visible' -or -not $st.focus)) {
        $lastAct = Get-Date
        [void](Force-ActivateBrowser -Nuke -WbSession $SessionName)
      }
    }
    Start-Sleep -Milliseconds 1500
  }
  return (Get-PageState $SessionName)
}

function Reload-Visible {
  # 强制激活 + 可见重载当前目标 URL（Gemini 在后台加载会进入降级态）
  param([string]$SessionName, [string]$Url, [string]$Group = "")
  [void](Force-ActivateBrowser -Nuke -WbSession $SessionName)
  $navArgs = @{ url = $Url }
  if ($Group) { $navArgs.group_title = $Group }
  try { Invoke-WB "navigate" $navArgs $SessionName | Out-Null } catch {}
  Start-Sleep -Milliseconds 800
  [void](Force-ActivateBrowser -WbSession $SessionName)
}

# ---------- 账号 ----------

function Ensure-Account {
  param([string]$SessionName, [int]$AcctIndex, [string]$ExpectEmail, [int]$MaxScan = 4, [string]$Group = "")
  # 返回 @{ index = N; email = ... } 或 $null
  # 自动检测模式：未指定邮箱 → 打开默认账号页，读取浏览器当前登录的 Gemini 账号
  if (-not $ExpectEmail) {
    Reload-Visible $SessionName (Get-HomeUrl -1) -Group $Group
    $stDef = Wait-PageReady $SessionName 90
    if ($stDef -and $stDef.email) {
      $idxDef = -1
      $md = [regex]::Match([string]$stDef.url, 'gemini\.google\.com/u/(\d+)/app')
      if ($md.Success) { $idxDef = [int]$md.Groups[1].Value }
      return @{ index = $idxDef; email = $stDef.email }
    }
    return $null
  }
  $tryIdx = @()
  if ($AcctIndex -ge 0) { $tryIdx += $AcctIndex }
  foreach ($n in 0..$MaxScan) { if ($tryIdx -notcontains $n) { $tryIdx += $n } }
  foreach ($n in $tryIdx) {
    $st = Get-PageState $SessionName
    if ($st -and $st.url -like "*gemini.google.com/u/$n/*" -and $st.email -eq $ExpectEmail) {
      return @{ index = $n; email = $st.email }
    }
    Reload-Visible $SessionName (Get-HomeUrl $n) -Group $Group
    $st = Wait-PageReady $SessionName 60
    if ($st -and $st.email -eq $ExpectEmail) { return @{ index = $n; email = $st.email } }
  }
  # 兜底：默认账号页（不带 /u/N 前缀，账号可能只在默认页可见）
  Reload-Visible $SessionName (Get-HomeUrl -1) -Group $Group
  $stFallback = Wait-PageReady $SessionName 90
  if ($stFallback -and $stFallback.email -eq $ExpectEmail) {
    $idxFb = -1
    $mf = [regex]::Match([string]$stFallback.url, 'gemini\.google\.com/u/(\d+)/app')
    if ($mf.Success) { $idxFb = [int]$mf.Groups[1].Value }
    return @{ index = $idxFb; email = $stFallback.email }
  }
  return $null
}

# ---------- 模式选择器（键盘导航） ----------

$JS_MENU = @'
(() => {
  const out = [];
  for (const e of document.querySelectorAll('gem-menu-item')) {
    const l = ((e.querySelector('.label') || {}).textContent || '').trim();
    const s = ((e.querySelector('.sublabel') || {}).textContent || '').trim();
    const r = e.getBoundingClientRect();
    out.push({ l, s, sel: e.classList.contains('selected'), vis: r.width > 0 });
  }
  return JSON.stringify(out);
})()
'@
$JS_ACTIVE_ITEM = @'
(() => {
  const ae = document.activeElement;
  return (ae && ae.tagName.toLowerCase() === 'gem-menu-item') ? ((ae.querySelector('.label') || {}).textContent || '').trim() : '';
})()
'@

function Get-MenuItems {
  param([string]$SessionName)
  try {
    $v = Eval-JS $JS_MENU $SessionName
    if (-not $v) { return @() }
    return @(($v | ConvertFrom-Json))
  } catch { return @() }
}
function Get-ActiveMenuItem {
  param([string]$SessionName)
  try { $v = Eval-JS $JS_ACTIVE_ITEM $SessionName; if ($v) { return "$v" } } catch {}
  return ""
}
function Send-Key {
  param([string]$SessionName, [string]$Key, [int]$VK, [int]$AfterMs = 260)
  Send-Cdp "Input.dispatchKeyEvent" @{ type = "rawKeyDown"; key = $Key; code = $Key; windowsVirtualKeyCode = $VK; nativeVirtualKeyCode = $VK } $SessionName | Out-Null
  Start-Sleep -Milliseconds 50
  Send-Cdp "Input.dispatchKeyEvent" @{ type = "keyUp"; key = $Key; code = $Key; windowsVirtualKeyCode = $VK; nativeVirtualKeyCode = $VK } $SessionName | Out-Null
  Start-Sleep -Milliseconds $AfterMs
}
function Send-Enter {
  param([string]$SessionName)
  Send-Cdp "Input.dispatchKeyEvent" @{ type = "keyDown"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13; text = "`r"; unmodifiedText = "`r" } $SessionName | Out-Null
  Start-Sleep -Milliseconds 80
  Send-Cdp "Input.dispatchKeyEvent" @{ type = "keyUp"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 } $SessionName | Out-Null
}
function Test-MenuOpen {
  param([string]$SessionName)
  try {
    $v = Eval-JS "!!([...document.querySelectorAll('.cdk-overlay-pane')].some(e=>e.getBoundingClientRect().width>0 && e.querySelector('gem-menu')))" $SessionName
    return ($v -eq $true)
  } catch { return $false }
}
function Open-ModePicker {
  param([string]$SessionName, [int]$WaitSec = 20)
  # 慢环境下菜单渲染可能需 10s+：每次点击后做有界轮询，而不是固定短等待
  for ($i = 0; $i -lt 3; $i++) {
    if (Test-MenuOpen $SessionName) { return $true }
    try { Invoke-WB "click" @{ selector = "button.input-area-switch" } $SessionName | Out-Null } catch {}
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 800
      if (Test-MenuOpen $SessionName) { return $true }
    }
  }
  return $false
}
function Wait-PickerLabel {
  # Enter 后模式选择器标签可能有延迟；有界轮询直到出现目标关键字
  param([string]$SessionName, [string]$Key, [int]$Seconds = 8)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $st = Get-PageState $SessionName
    if ($st -and $st.picker -and (($st.picker -replace '\s', '') -like "*$Key*")) { return $st }
    Start-Sleep -Milliseconds 600
  }
  return (Get-PageState $SessionName)
}
function Close-ModePicker {
  param([string]$SessionName)
  Send-Key $SessionName "Escape" 27 250
}
function Select-MenuItem {
  # 在已打开的菜单里键盘导航到目标（若在子菜单目标，需先 Hover-ToSubmenu 打开子菜单）
  param([string]$SessionName, [string]$Target, [int]$MaxSteps = 9)
  $a = Get-ActiveMenuItem $SessionName
  if ($a -eq $Target) { return $true }
  for ($i = 0; $i -lt $MaxSteps; $i++) {
    Send-Key $SessionName "ArrowDown" 40 300
    $a = Get-ActiveMenuItem $SessionName
    if ($a -eq $Target) { return $true }
  }
  return $false
}
function Set-ModelPreference {
  # 选模型（主菜单项）。返回实际生效的模型标签或 $null（未变更/失败）
  param([string]$SessionName)
  $stPk = Get-PageState $SessionName
  $cur = if ($stPk) { $stPk.picker } else { $null }
  if (-not $cur) { Write-Warning "拿不到模式选择器状态，跳过模型设置"; return $null }
  $curNorm = ($cur -replace '\s', '')
  foreach ($m in $MODEL_PREF) {
    $key = ($m -replace '^\d+(\.\d+)?\s*', '')   # "4 Argon" -> "Argon"
    if ($curNorm -like "*$key*") { Write-Warning "模型已是 '$m'（$cur），跳过设置"; return $m }
  }
  if (-not (Open-ModePicker $SessionName)) { Write-Warning "模式选择器打不开，模型保持现状: $cur"; return $null }
  $items = @(Get-MenuItems $SessionName | Where-Object { $_.vis })
  $target = $null
  foreach ($m in $MODEL_PREF) { if ($items | Where-Object { $_.l -eq $m }) { $target = $m; break } }
  if (-not $target) { Write-Warning "菜单中没有已知模型项，保持现状"; Close-ModePicker $SessionName; return $null }
  Write-Warning "设置模型: $target"
  if (-not (Select-MenuItem $SessionName $target)) {
    Write-Warning "导航到 '$target' 失败（active=$(Get-ActiveMenuItem $SessionName)）"
    Close-ModePicker $SessionName
    return $null
  }
  Send-Enter $SessionName
  $key = ($target -replace '^\d+(\.\d+)?\s*', '')
  $st = Wait-PickerLabel $SessionName $key 8
  if ($st -and $st.picker -and (($st.picker -replace '\s', '') -like "*$key*")) { return $target }
  Write-Warning "模型设置后校验不通过（picker=$($st.picker)）"
  return $null
}
function Set-ThinkingPreference {
  param([string]$SessionName)
  $st0 = Get-PageState $SessionName
  $curNorm = if ($st0 -and $st0.picker) { ($st0.picker -replace '\s', '') } else { "" }
  foreach ($t in $THINKING_PREF) {
    if ($curNorm -like "*$($t -replace '\s','')*") { Write-Warning "思考档已是 '$t'（$curNorm），跳过设置"; return $t }
  }
  if (-not (Open-ModePicker $SessionName)) { Write-Warning "模式选择器打不开，思考档保持现状"; return $null }
  # 到「思考等级」父项
  if (-not (Select-MenuItem $SessionName "思考等级")) {
    Write-Warning "找不到「思考等级」项"
    Close-ModePicker $SessionName
    return $null
  }
  Send-Key $SessionName "ArrowRight" 39 700
  # 子菜单可见项
  $items = @(Get-MenuItems $SessionName | Where-Object { $_.vis })
  $target = $null
  foreach ($t in $THINKING_PREF) { if ($items | Where-Object { $_.l -eq $t }) { $target = $t; break } }
  if (-not $target) { Write-Warning "子菜单中没有已知思考档，保持现状"; Close-ModePicker $SessionName; return $null }
  Write-Warning "设置思考档: $target"
  $a = Get-ActiveMenuItem $SessionName
  if ($a -eq "思考等级" -or -not ($a -in @("低点", "中等", "高点", "Deep Think"))) {
    Send-Key $SessionName "ArrowRight" 39 500
    $a = Get-ActiveMenuItem $SessionName
    if (-not ($a -in @("低点", "中等", "高点", "Deep Think"))) { Send-Key $SessionName "ArrowDown" 40 400 }
  }
  if (-not (Select-MenuItem $SessionName $target)) {
    Write-Warning "导航到思考档 '$target' 失败"
    Close-ModePicker $SessionName
    return $null
  }
  Send-Enter $SessionName
  $st = Wait-PickerLabel $SessionName ($target -replace '\s', '') 8
  if ($st -and $st.picker -and (($st.picker -replace '\s', '') -like "*$($target -replace '\s','')*")) { return $target }
  Write-Warning "思考档设置后校验不通过（picker=$($st.picker)）"
  return $null
}

# ---------- 输入 / 发送 ----------

function Fill-Question {
  param([string]$SessionName, [string]$TextValue)
  $r = $null
  try { $r = Invoke-WB "fill" @{ selector = ".ql-editor"; value = $TextValue } $SessionName } catch {}
  if (-not $r -or -not $r.success) {
    try { Invoke-WB "click" @{ selector = ".ql-editor" } $SessionName | Out-Null } catch {}
    Start-Sleep -Milliseconds 600
    try { $r = Invoke-WB "fill" @{ selector = ".ql-editor"; value = $TextValue } $SessionName } catch {}
  }
  return ($r -and $r.success)
}
function Wait-SendButton {
  param([string]$SessionName, [int]$Seconds = 25)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $st = Get-PageState $SessionName
    if ($st -and $st.send) { return $true }
    Start-Sleep -Milliseconds 900
  }
  return $false
}

# ---------- 答案读取（DOM -> Markdown 重建） ----------

$JS_TO_MD = @'
(() => {
  const resp = [...document.querySelectorAll('model-response')].pop();
  if (!resp) return '';
  const root = resp.querySelector('.markdown') || resp;
  const inline = (el) => {
    let out = '';
    for (const n of el.childNodes) {
      if (n.nodeType === 3) { out += n.textContent; continue; }
      if (n.nodeType !== 1) continue;
      const t = n.tagName.toLowerCase();
      if (t === 'br') { out += '\n'; continue; }
      // 公式：优先用 data-math 属性还原 TeX（KaTeX 的 MathML/HTML 双层会重复文本）
      const mathTex = n.getAttribute && n.getAttribute('data-math');
      if (mathTex && mathTex.indexOf('$') < 0) {
        const block = n.classList && n.classList.contains('math-block');
        out += (block ? '$$' : '$') + mathTex.trim() + (block ? '$$' : '$');
        continue;
      }
      if (n.classList && n.classList.contains('katex')) {
        const khtml = n.querySelector('.katex-html');
        const vis = ((khtml ? khtml.textContent : n.textContent) || '').trim();
        if (vis) out += '$' + vis + '$';
        continue;
      }
      if (n.classList && n.classList.contains('katex-mathml')) { continue; }
      if (t === 'code') { out += '`' + n.textContent.replace(/`/g, '\\`') + '`'; continue; }
      if (t === 'strong' || t === 'b') { out += '**' + inline(n).trim() + '**'; continue; }
      if (t === 'em' || t === 'i') { out += '*' + inline(n).trim() + '*'; continue; }
      if (t === 'a') { const h = n.getAttribute('href') || ''; out += '[' + inline(n).trim() + '](' + h + ')'; continue; }
      out += inline(n);
    }
    return out;
  };
  const cell = (td) => inline(td).replace(/\|/g, '\\|').replace(/\n+/g, ' ').trim();
  let out = '';
  const walk = (el) => {
    for (const n of el.children) {
      const t = n.tagName.toLowerCase();
      if (/^(h[1-6])$/.test(t)) {
        out += '\n' + '#'.repeat(parseInt(t[1], 10)) + ' ' + inline(n).trim() + '\n\n';
      } else if (t === 'p') {
        const tx = inline(n).trim();
        if (tx) out += tx + '\n\n';
      } else if (t === 'pre') {
        const codeEl = n.querySelector('code') || n;
        let lang = '';
        const holder = n.closest('code-block') || n.parentElement;
        const deco = holder ? holder.querySelector('.code-block-decoration span') : null;
        if (deco && deco.textContent.trim().length <= 20) lang = deco.textContent.trim();
        else { const cm = (codeEl.className || '').match(/language-([\w+#-]+)/); if (cm) lang = cm[1]; }
        out += '```' + lang + '\n' + codeEl.textContent.replace(/\n$/, '') + '\n```\n\n';
      } else if (t === 'table') {
        const rows = [...n.querySelectorAll('tr')];
        rows.forEach((tr, ri) => {
          const cells = [...tr.querySelectorAll('th,td')].map(cell);
          out += '| ' + cells.join(' | ') + ' |\n';
          if (ri === 0) out += '|' + cells.map(() => '---').join('|') + '|\n';
        });
        out += '\n';
      } else if (t === 'ul' || t === 'ol') {
        [...n.children].forEach((li, i) => {
          const mark = t === 'ul' ? '- ' : (i + 1) + '. ';
          out += mark + inline(li).trim().replace(/\n/g, '\n  ') + '\n';
        });
        out += '\n';
      } else if (t === 'blockquote') {
        out += inline(n).trim().split('\n').map(l => '> ' + l).join('\n') + '\n\n';
      } else if (t === 'hr') {
        out += '---\n\n';
      } else {
        walk(n);
      }
    }
  };
  walk(root);
  return out.trim();
})()
'@

function Get-LastAnswerMarkdown {
  param([string]$SessionName)
  try {
    $v = Eval-JS $JS_TO_MD $SessionName
    if ($v) { return "$v" }
  } catch {}
  return ""
}

# ============================ -ListChats / -Attach ============================

function Get-SidebarChats {
  param([string]$SessionName, [int]$LimitN = 30)
  $js = @"
(() => {
  const out = [];
  for (const a of document.querySelectorAll('a')) {
    const href = a.getAttribute('href') || '';
    const m = href.match(/^\/(?:u\/\d+\/)?app\/([0-9a-f]{8,})$/);
    if (!m) continue;
    const r = a.getBoundingClientRect();
    if (r.width <= 0) continue;
    out.push({ id: m[1], title: (a.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 80) });
    if (out.length >= $LimitN) break;
  }
  return JSON.stringify(out);
})()
"@
  try {
    $v = Eval-JS $js $SessionName
    if (-not $v) { return @() }
    return @(($v | ConvertFrom-Json))
  } catch { return @() }
}
function Ensure-SidebarOpen {
  # 目标：让侧栏会话链接出现在 DOM。列表是「展开时懒创建」的；
  # 折叠态下与「主菜单」按钮都可能是懒渲染的 → 轮询 + 有限次重试点击。
  param([string]$SessionName, [int]$Seconds = 30)
  try {
    $linksJs = '(()=>[...document.querySelectorAll("a")].filter(a=>/^\/(?:u\/\d+\/)?app\/[0-9a-f]+$/.test(a.getAttribute("href")||"")).length)()'
    $dl = (Get-Date).AddSeconds($Seconds)
    $clicks = 0
    $lastClick = (Get-Date).AddMinutes(-10)
    while ((Get-Date) -lt $dl) {
      if ([int](Eval-JS $linksJs $SessionName) -gt 0) { return $true }
      if ($clicks -lt 3 -and ((Get-Date) - $lastClick).TotalSeconds -gt 5) {
        $hasMain = Eval-JS '!!document.querySelector("button[aria-label=\"主菜单\"]")' $SessionName
        if ($hasMain -eq $true) {
          $clicks++
          $lastClick = Get-Date
          Write-Warning "侧栏会话列表为空，点击「主菜单」展开侧栏（第 $clicks 次）"
          Invoke-WB "click" @{ selector = 'button[aria-label="主菜单"]' } $SessionName | Out-Null
        }
      }
      Start-Sleep -Milliseconds 1600
    }
    $n = [int](Eval-JS $linksJs $SessionName)
    Write-Warning "侧栏展开尝试结束（clicks=$clicks, links=$n）"
    return ($n -gt 0)
  } catch {
    Write-Warning "侧栏展开异常: $($_.Exception.Message)"
    return $false
  }
}
function Get-LocalAnchorMap {
  $map = @{}
  foreach ($st in (Get-AllStates)) {
    if ($st.convUrl -and $st.session) { $cid = Get-ConvId $st.convUrl; if ($cid) { $map[$cid] = $st.session } }
  }
  return $map
}
function Wait-SidebarChats {
  # 侧栏会话列表是异步水合的：轮询直到出现条目或超时。
  # 最小打扰：每 ~10s 才检查一次可见性，且只做软激活（不最小化/还原）。
  param([string]$SessionName, [int]$Seconds = 35, [int]$MinCount = 1)
  $dl = (Get-Date).AddSeconds($Seconds)
  $last = @()
  $loopN = 0
  while ((Get-Date) -lt $dl) {
    $last = Get-SidebarChats -SessionName $SessionName -LimitN 60
    if (@($last).Count -ge $MinCount) { return $last }
    Start-Sleep -Milliseconds 2000
    $loopN++
    if ($loopN % 5 -eq 0) {
      $st = Get-PageState $SessionName
      if ($st -and ($st.vis -ne 'visible' -or -not $st.focus)) { [void](Force-ActivateBrowser -WbSession $SessionName) }
    }
  }
  return $last
}
function Wait-PickerState {
  # 模式选择器可能晚于页面就绪渲染：轮询等待
  param([string]$SessionName, [int]$Seconds = 25)
  $dl = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $dl) {
    $st = Get-PageState $SessionName
    if ($st -and $st.picker) { return $st }
    Start-Sleep -Milliseconds 1500
  }
  return (Get-PageState $SessionName)
}

# ============================ 主流程 ============================

# ---- -Status（只读）----
if ($Status) {
  $all = Get-AllStates | Where-Object { $_ -and $_.session }
  if (-not $all) {
    Write-Output "（还没有任何已记录的讨论）"
    Write-Output "state 目录: $STATE_DIR"
    exit 0
  }
  Write-Output ("state 目录: " + $STATE_DIR)
  Write-Output ""
  Write-Output ("{0,-22} {1,6}  {2,-19}  {3}" -f "session", "rounds", "updatedAt", "conv / doc")
  foreach ($s in ($all | Sort-Object updatedAt -Descending)) {
    Write-Output ("{0,-22} {1,6}  {2,-19}  {3}" -f $s.session, $s.rounds, $s.updatedAt, $s.convUrl)
    if ($s.docPath) { Write-Output ("{0,-22} {1,6}  {2,-19}  {3}" -f "", "", "", $s.docPath) }
    Write-Output ("{0,-22} {1,6}  {2,-19}  账号={3} 模式={4}" -f "", "", "", $s.account, $s.mode)
  }
  exit 0
}

# ---- 解析 session / 文档 / 锚点 ----

if (-not $Question -and -not $CloseExtras -and -not $Attach -and -not $ListChats) {
  Fail 13 "-Question 必填（或改用 -Status / -ListChats / -Attach / -CloseExtras）"
}

function Get-SlugFromDoc {
  param([string]$P)
  $n = [IO.Path]::GetFileNameWithoutExtension($P)
  $n = $n -replace '^\d{4}-\d{2}-\d{2}[-_]', ''
  $n = $n.Trim('-', '_')
  if (-not $n) { $n = "gemini-discuss" }
  return $n
}
function New-SessionSlugFromCwd {
  $raw = Split-Path (Get-Location) -Leaf
  $slug = ($raw.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
  if (-not $slug) { $slug = "gemini-discuss" }
  return $slug
}

if (-not $Session) {
  if ($DocPath) { $Session = Get-SlugFromDoc $DocPath }
  else {
    $cwd = (Get-Location).Path
    $cands = @(Get-AllStates | Where-Object { $_.session -and $_.docPath -and $_.docPath.StartsWith($cwd, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object updatedAt -Descending)
    if ($cands.Count -gt 0 -and -not ($New -or $ForceNew)) {
      $Session = $cands[0].session
      Write-Warning "未指定 -Session，复用当前工作区最近使用的讨论 '$Session'"
    } else {
      $Session = New-SessionSlugFromCwd
      Write-Warning "未指定 -Session，按工作区新建讨论 '$Session'"
    }
  }
}
if ($Session -notmatch '^[A-Za-z0-9._-]+$') { Fail 13 "-Session 只允许字母/数字/._-（当前: $Session）" }
# webbridge 会话名与本地 slug 分开：避免与 chatgpt-discuss 的标签组混淆
$WB_SESSION = "gem-$Session"
$SCAN_SESSION = "gem-browse"

$state = Read-DiscussState $Session

# 已记录账号索引（-ForceNew 不改账号）
$acctIndex = -1
if ($state -and $null -ne $state.accountIndex) { $acctIndex = [int]$state.accountIndex }
$acctEmail = $Account
if (-not $acctEmail -and $state -and $state.account) { $acctEmail = [string]$state.account }

if (-not $DocPath) {
  if ($state -and $state.docPath) { $DocPath = $state.docPath }
  else {
    $qaDir = Join-Path (Get-Location) "docs/gemini_qa"
    if (Test-Path $qaDir) {
      $pat = "(^|[-_])" + [regex]::Escape($Session) + "$"
      $ex = Get-ChildItem $qaDir -Filter "*.md" -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match $pat } | Select-Object -First 1
      if ($ex) { $DocPath = $ex.FullName }
    }
    if (-not $DocPath) { $DocPath = Join-Path (Get-Location) ("docs/gemini_qa/{0}-{1}.md" -f (Get-Date -Format "yyyy-MM-dd"), $Session) }
  }
}
$DocPath = [IO.Path]::GetFullPath($DocPath)

# ---- -ListChats（只读；不提问、不改文档、不加锁） ----
if ($ListChats) {
  Connect-Daemon
  [void](Force-ActivateBrowser -Nuke -WbSession $SCAN_SESSION)
  $acctL = Ensure-Account -SessionName $SCAN_SESSION -AcctIndex $acctIndex -ExpectEmail $Account -Group "Gemini讨论：会话浏览"
  if (-not $acctL) { Fail 14 "浏览器里找不到目标账号（已扫描 u/0..u/4 与默认账号页）。请先在浏览器登录 Google 账号。" }
  [void](Wait-PageReady -SessionName $SCAN_SESSION -Seconds 90)
  if (-not (Ensure-SidebarOpen -SessionName $SCAN_SESSION)) { Write-Warning "侧栏未确认打开，仍尝试读取…" }
  $chats = Wait-SidebarChats -SessionName $SCAN_SESSION -Seconds 35 -MinCount 1
  if (@($chats).Count -eq 0) {
    Write-Warning "侧栏列表为空（可能水合未完成），可见重载后重试…"
    Reload-Visible $SCAN_SESSION (Get-HomeUrl $acctL.index) -Group "Gemini讨论：会话浏览"
    [void](Wait-PageReady -SessionName $SCAN_SESSION -Seconds 90)
    [void](Ensure-SidebarOpen -SessionName $SCAN_SESSION)
    $chats = Wait-SidebarChats -SessionName $SCAN_SESSION -Seconds 50 -MinCount 1
  }
  $chats = @($chats | Select-Object -First $Limit)
  Write-Output ("Gemini 账号 $($acctL.email)（u/$($acctL.index)）侧栏可见会话 $($chats.Count) 条（最多 $Limit）：")
  Write-Output ""
  $map = Get-LocalAnchorMap
  Write-Output ("{0,-40} {1}" -f "标题", "会话 id")
  foreach ($c in $chats) {
    $t = if ($c.title) { $c.title } else { "(无标题)" }
    if ($t.Length -gt 36) { $t = $t.Substring(0, 35) + "…" }
    $mark = if ($map.ContainsKey($c.id)) { "  ← 已锚定: " + $map[$c.id] } else { "" }
    Write-Output ("{0,-40} {1}{2}" -f $t, $c.id, $mark)
  }
  Write-Output ""
  Write-Output "想接管其中某条：ask-gemini.ps1 -Attach <标题关键字 或 会话id> -Session <你的讨论slug>"
  exit 0
}

# ---- -Attach 解析（标题关键字 / 裸 id / 链接 → ConvUrl） ----
if ($Attach) {
  $aid = Get-ConvId $Attach
  if (-not $aid -and $Attach -match '^[0-9a-f]{8,}$') { $aid = $Attach }
  if ($aid) {
    Write-Warning "Attach: 直接使用给出的会话 id $aid"
  } else {
    Connect-Daemon
    [void](Force-ActivateBrowser -Nuke -WbSession $SCAN_SESSION)
    $acctA = Ensure-Account -SessionName $SCAN_SESSION -AcctIndex $acctIndex -ExpectEmail $Account -Group "Gemini讨论：会话浏览"
    if (-not $acctA) { Fail 14 "浏览器里找不到目标账号（已扫描 u/0..u/4 与默认账号页）。" }
    $acctIndex = [int]$acctA.index
    [void](Wait-PageReady -SessionName $SCAN_SESSION -Seconds 90)
    [void](Ensure-SidebarOpen -SessionName $SCAN_SESSION)
    $chats = Wait-SidebarChats -SessionName $SCAN_SESSION -Seconds 35 -MinCount 1
    if (@($chats).Count -eq 0) {
      Write-Warning "侧栏列表为空（可能水合未完成），可见重载后重试…"
      Reload-Visible $SCAN_SESSION (Get-HomeUrl $acctIndex) -Group "Gemini讨论：会话浏览"
      [void](Wait-PageReady -SessionName $SCAN_SESSION -Seconds 90)
      [void](Ensure-SidebarOpen -SessionName $SCAN_SESSION)
      $chats = Wait-SidebarChats -SessionName $SCAN_SESSION -Seconds 50 -MinCount 1
    }
    $hits = @($chats | Where-Object { $_.title -and $_.title -like "*$Attach*" })
    if ($hits.Count -eq 0) { Fail 13 "侧栏没有标题包含 '$Attach' 的会话。先跑 -ListChats 看列表，或直接给 /app/<id>" }
    if ($hits.Count -gt 1) {
      Write-Output "标题 '$Attach' 匹配到 $($hits.Count) 条，请给更精确的关键字或直接给 id："
      foreach ($h in $hits) { Write-Output ("  {0}  {1}" -f $h.id, $h.title) }
      Fail 13 "Attach 目标不唯一"
    }
    $aid = $hits[0].id
    Write-Warning "Attach: '$Attach' → $($hits[0].title)  [$aid]"
  }
  $ConvUrl = Get-CanonicalConvUrl ("https://gemini.google.com/app/" + $aid) $acctIndex
}

# 锚点解析优先级: -ConvUrl > 文档标记 > state
$anchor = $null; $anchorSrc = $null
if ($ConvUrl) {
  $anchor = Get-CanonicalConvUrl $ConvUrl
  if (-not $anchor) { Fail 13 "-ConvUrl 不是合法的 gemini.google.com/.../app/<id> 链接: $ConvUrl" }
  $anchorSrc = "参数"
}
if (-not $anchor) {
  $mk = Get-DocMarker $DocPath
  if ($mk -and $mk['conv'] -and $mk['conv'] -ne 'none') {
    $anchor = Get-CanonicalConvUrl $mk['conv']
    if ($anchor) { $anchorSrc = "文档" }
  }
}
if (-not $anchor -and $state -and $state.convUrl) {
  $anchor = Get-CanonicalConvUrl $state.convUrl
  if ($anchor) { $anchorSrc = "state" }
}
# 旧格式文档：正文头部有 /app/<id> 链接 → 认领
if (-not $anchor) {
  $txt = Read-Text $DocPath
  if ($txt) {
    $head = if ($txt.Length -gt 3000) { $txt.Substring(0, 3000) } else { $txt }
    $m = [regex]::Match($head, 'gemini\.google\.com/(?:u/\d+/)?app/([0-9a-f]{8,})')
    if ($m.Success) {
      $anchor = Get-CanonicalConvUrl ("https://gemini.google.com/app/" + $m.Groups[1].Value)
      $anchorSrc = "文档(旧格式链接)"
      Write-Warning "该文档无 gemini-discuss 标记，已从正文认领会话链接作锚点: $anchor"
    }
  }
}
if ($anchor -and $state -and $state.convUrl) {
  $sc = Get-ConvId $state.convUrl
  if ($sc -and $sc -ne (Get-ConvId $anchor)) { Write-Warning "文档标记与 state 不一致，以 $anchorSrc 为准，已自愈 state" }
}

if ($anchor -and ($New -and -not $ForceNew)) {
  Fail 10 @"
讨论 '$Session' 已经有一条会话线程，拒绝新建。
  现有会话: $anchor
  要接着聊（推荐）: 去掉 -New 重跑同样的命令
  确实要开新线程  : 加 -ForceNew（旧链接会归档进 state 的 convHistory）
  想看看都有哪些   : pwsh -File ask-gemini.ps1 -Status
"@
}

$creating = (-not $anchor) -or $ForceNew
if ($state) {
  if (-not $GroupTitle -and $state.groupTitle) { $GroupTitle = $state.groupTitle }
  if (-not $Title -and $state.title) { $Title = $state.title }
}
if (-not $Title) { $Title = if ($GroupTitle) { $GroupTitle -replace '^Gemini讨论[：:]\s*', '' } else { $Session } }
if (-not $GroupTitle) { $GroupTitle = "Gemini讨论：$Title" }
if ($Title.Length -gt 60) { $Title = $Title.Substring(0, 60) }

Write-Warning "session=$Session | 文档=$DocPath"
Write-Warning "账号=$(if ($acctEmail) { $acctEmail } else { '自动检测（浏览器当前登录）' }) | 首选模式=$($MODEL_PREF[0]) + $($THINKING_PREF[0])"
Write-Warning ("模式=" + $(if ($creating) { "新建会话线程" } else { "续聊（锚点来自$anchorSrc）" }) + $(if ($anchor) { " | $anchor" } else { "" }))

# ---- -Attach 纯绑定 ----
if ($Attach -and -not $Question) {
  if (-not $anchor) { Fail 13 "-Attach 已解析但没拿到有效锚点" }
  $hist = @(); if ($state -and $state.convHistory) { $hist = @($state.convHistory) }
  if ($state -and $state.convUrl) {
    $oc = Get-CanonicalConvUrl $state.convUrl
    if ($oc -and (Get-ConvId $oc) -ne (Get-ConvId $anchor) -and $hist -notcontains $oc) { $hist += $oc; Write-Warning "旧锚点已归档进 convHistory: $oc" }
  }
  $rd = Get-DocRoundCount $DocPath
  Write-DiscussState $Session (@{
    session = $Session; convUrl = $anchor; convHistory = $hist; docPath = $DocPath
    title = $Title; groupTitle = $GroupTitle; rounds = $rd
    account = $acctEmail; accountIndex = $acctIndex; mode = $(if ($state) { $state.mode } else { $null })
    createdAt = $(if ($state -and $state.createdAt) { $state.createdAt } else { (Get-Date).ToString("s") })
    updatedAt = (Get-Date).ToString("s")
  })
  if (-not (Test-Path $DocPath)) { Write-DocHeader -Path $DocPath -DocTitle $Title -S $Session -Curl $anchor -Acct $acctEmail -Mode "-" }
  Update-DocMarker -Path $DocPath -S $Session -Curl $anchor -Acct $acctEmail -Mode $(if ($state) { $state.mode } else { "-" }) -Rounds $rd
  Write-Warning "已绑定（本轮未发问）: session=$Session → $anchor"
  Write-Warning "文档: $DocPath （已有 $rd 轮）"
  $anchor
  exit 0
}

# ---- 锁 + daemon ----
if (-not (Acquire-Lock $Session)) {
  Fail 12 "session '$Session' 已有另一个 ask-gemini 进程在运行（锁文件未过期）。等它跑完再试——不要并发。"
}
Connect-Daemon

$script:WbSession = $WB_SESSION
$script:ConvUrl = $anchor
[void](Force-ActivateBrowser -Nuke)

# ---- 账号确认 ----
$acct = Ensure-Account -SessionName $WB_SESSION -AcctIndex $acctIndex -ExpectEmail $acctEmail -Group $GroupTitle
if (-not $acct) { Fail 14 "浏览器里找不到目标账号（已扫描 u/0..u/4 与默认账号页）。请先在浏览器登录对应 Google 账号。" }
$acctEmail = [string]$acct.email
$acctIndex = [int]$acct.index
Write-Warning "账号确认: $acctEmail（u/$acctIndex）"

# 补全账号索引到会话 URL（Attach/裸 id 场景可能缺 /u/N）
if ($script:ConvUrl -and $script:ConvUrl -notmatch '/u/\d+/') {
  $script:ConvUrl = Get-CanonicalConvUrl $script:ConvUrl $acctIndex
  $anchor = $script:ConvUrl
  Write-Warning "已补全账号索引: $anchor"
}

# ---- 打开目标页面 ----
if ($creating) {
  Write-Warning "打开 Gemini 新对话（/u/$acctIndex/app）"
  Reload-Visible $WB_SESSION (Get-HomeUrl $acctIndex) -Group $GroupTitle
  $st = Wait-PageReady -SessionName $WB_SESSION -Seconds 120
  if (-not $st -or -not $st.ed) { Fail 5 "Gemini 新对话页未就绪（40s 内没看到输入框）——可能是登录墙/加载失败/改版" }
  # 确保从零态开始（若恢复了上次会话，点“发起新对话”）
  if ($st.uq -gt 0) {
    Write-Warning "页面非零态，点击「发起新对话」"
    try { Invoke-WB "click" @{ selector = "a[aria-label=`"发起新对话`"], a[href$=`"/app`"]" } $WB_SESSION | Out-Null } catch {}
    Start-Sleep -Seconds 2
    [void](Wait-PageReady -SessionName $WB_SESSION -Seconds 60)
  }
} else {
  $convId = Get-ConvId $anchor
  $tab = Resolve-ConvTab -SessionName $WB_SESSION -ConvId $convId -MaxRecover $MaxRecover -Group $GroupTitle
  if (-not $tab) { Fail 6 "有锚点 $anchor，但既找不到标签也开不出标签。不要用 -New！可先跑 -Status 看记录。" }
  if (-not $NoDedupe) {
    $closed = Close-StrayTabs -SessionName $WB_SESSION -KeepConvId $convId
    if ($closed -gt 0) {
      $tab = Resolve-ConvTab -SessionName $WB_SESSION -ConvId $convId -MaxRecover 1 -Group $GroupTitle
      if (-not $tab) { Fail 6 "清理游离标签后无法回到锚定会话（不要用 -New）" }
    }
  }
  # 就绪检测：已有会话应能看到历史消息（uq>=1）；否则可见重载一次
  $st = Wait-PageReady -SessionName $WB_SESSION -Seconds 90 -MinUq 1
  if (-not $st -or [int]$st.uq -lt 1) {
    Write-Warning "会话内容未渲染（Gemini 后台加载降级态），执行可见重载…"
    Reload-Visible $WB_SESSION $anchor -Group $GroupTitle
    $st = Wait-PageReady -SessionName $WB_SESSION -Seconds 120 -MinUq 1
  }
  if (-not $st -or -not $st.ed) { Fail 5 "Gemini 页面未就绪（会话页加载失败）" }
  if ([int]$st.uq -lt 1) { Fail 6 "锚定会话 $anchor 打开后看不到任何消息（可能账号不符/会话被删）" }
}

# ---- CloseExtras / 无问题快速出口 ----
if ($CloseExtras) {
  $keepId = Get-ConvId $script:ConvUrl
  Write-Warning "CloseExtras: 关闭该 session 内不属于本讨论的 gemini 标签"
  $closed = 0
  foreach ($t in (Get-SessionGeminiTabs $WB_SESSION)) {
    if ($closed -ge 20) { break }
    if ($keepId -and (Get-ConvId $t.url) -eq $keepId) { continue }
    try { Invoke-WB "find_tab" @{ url = $t.url } $WB_SESSION | Out-Null; Invoke-WB "close_tab" @{} $WB_SESSION | Out-Null; $closed++ } catch {}
  }
  Write-Warning "CloseExtras: 关闭 $closed 个"
  if (-not $Question) { Release-Lock; exit 0 }
}

# ---- 发送前硬校验 ----
if (-not $creating) {
  $convId = Get-ConvId $anchor
  $deadline = (Get-Date).AddSeconds(30)
  $ok = $false; $href = ""
  while ((Get-Date) -lt $deadline) {
    try { $href = Eval-JS "location.href" $WB_SESSION } catch {}
    if ($href -and (Get-ConvId $href) -eq $convId) { $ok = $true; break }
    Start-Sleep -Milliseconds 1200
  }
  if (-not $ok) { Fail 11 "发送前校验失败：当前页面 '$href' 不是锚定会话 $anchor。请检查该标签是否被手动导航走了（不要用 -New 绕开）" }
}

# ---- 模式设置（尽力而为；失败只告警不阻断） ----
# 说明：会话页在隐藏态加载时可能不渲染模式选择器（可见才渲染家族）→ 短等待 + 沿用记录值
[void](Wait-PickerState $WB_SESSION 8)
$modeActual = $null
$modelActual = Set-ModelPreference $WB_SESSION
$thinkingActual = Set-ThinkingPreference $WB_SESSION
if ($modelActual -and $thinkingActual) { $modeActual = "$modelActual $thinkingActual" }
elseif ($modelActual) { $modeActual = $modelActual }
elseif ($thinkingActual) { $modeActual = $thinkingActual }
if (-not $modeActual) {
  $stNow = Get-PageState $WB_SESSION
  if ($stNow -and $stNow.picker) {
    $modeActual = ($stNow.picker -replace '\s', '')
  } elseif ($state -and $state.mode -and $state.mode -ne '未校验') {
    $modeActual = "$($state.mode)"
    Write-Warning "本轮未能复核模式（选择器未渲染），沿用记录值: $modeActual"
  } else {
    $modeActual = "未校验"
  }
}
Write-Warning "模式确认: $modeActual"

# ---- 填入 + 发送（含一次受控恢复） ----

$script:BaseUq = 0
$st0 = Get-PageState $WB_SESSION
if ($st0) { $script:BaseUq = [int]$st0.uq }

function Try-SendRound {
  param([string]$SessionName, [string]$TextValue, [switch]$AllowRecovery)
  # 返回 @{ sent = $bool; st = (最新页面状态) }
  [void](Force-ActivateBrowser)
  if (-not (Fill-Question $SessionName $TextValue)) { return @{ sent = $false; err = 'fill' } }
  if (-not (Wait-SendButton $SessionName 25)) {
    if (-not $AllowRecovery) { return @{ sent = $false; err = 'gate' } }
    Write-Warning "发送键闸门超时（页面降级态），执行可见重载后重试…"
    Reload-Visible $SessionName $script:ConvUrl -Group $script:GroupTitle
    if ($script:Creating) {
      [void](Wait-PageReady -SessionName $SessionName -Seconds 40)
    } else {
      [void](Wait-PageReady -SessionName $SessionName -Seconds 45 -MinUq $script:BaseUq)
    }
    $script:BaseUq = 0
    $stx = Get-PageState $SessionName
    if ($stx) { $script:BaseUq = [int]$stx.uq }
    if (-not (Fill-Question $SessionName $TextValue)) { return @{ sent = $false; err = 'fill2' } }
    if (-not (Wait-SendButton $SessionName 25)) { return @{ sent = $false; err = 'gate2' } }
  }
  Send-Enter $SessionName
  Start-Sleep -Milliseconds 1200
  # 核实发送：uq 是否 +1
  $dl = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $dl) {
    $st = Get-PageState $SessionName
    if ($st -and [int]$st.uq -gt $script:BaseUq) { return @{ sent = $true; st = $st } }
    Start-Sleep -Milliseconds 1200
  }
  # DOM 未反映 → 可见重载后用会话记录核实（绝不盲发）
  if (-not $AllowRecovery) { return @{ sent = $false; err = 'unverified' } }
  Write-Warning "发送后 DOM 未更新，可见重载以核实（不盲重试）…"
  $checkUrl = $script:ConvUrl
  if ($script:Creating) {
    try {
      $hrefNow = Eval-JS "location.href" $SessionName
      $cNow = Get-CanonicalConvUrl $hrefNow
      if ($cNow) { $checkUrl = $cNow; $script:ConvUrl = $cNow; Write-Warning "已从地址栏捕获会话链接: $cNow" }
    } catch {}
  }
  Reload-Visible $SessionName $checkUrl -Group $script:GroupTitle
  $st = Wait-PageReady -SessionName $SessionName -Seconds 45 -MinUq ($script:BaseUq + 1)
  if ($st -and [int]$st.uq -gt $script:BaseUq) { return @{ sent = $true; st = $st; viaReload = $true } }
  return @{ sent = $false; err = 'unverified2' }
}

$script:Creating = $creating
if ($creating) { $script:ConvUrl = Get-HomeUrl $acctIndex }

$sendRes = Try-SendRound -SessionName $WB_SESSION -TextValue $Question -AllowRecovery
if (-not $sendRes.sent -and $sendRes.err -eq 'fill') { Fail 7 "填入问题失败（.ql-editor 不可用，可能是页面改版）" }
if (-not $sendRes.sent -and $sendRes.err -eq 'gate') { Fail 7 "填入后发送键未出现（页面降级且恢复失败）——稍后重跑同一条命令即可" }
if (-not $sendRes.sent -and $sendRes.err -eq 'fill2') { Fail 7 "恢复后填入问题仍失败" }
if (-not $sendRes.sent -and $sendRes.err -eq 'gate2') { Fail 7 "恢复后发送键仍未出现——稍后重跑同一条命令即可" }
if (-not $sendRes.sent) { Fail 8 "发送失败（已两次核实会话中没有新提问）。请检查浏览器状态后重跑；不要连续重试以免重复提问" }

# 发送成功：新建模式捕获会话链接
if ($creating) {
  $dl = (Get-Date).AddSeconds(30)
  $captured = $null
  while ((Get-Date) -lt $dl) {
    try {
      $href = Eval-JS "location.href" $WB_SESSION
      $c = Get-CanonicalConvUrl $href $acctIndex
      if ($c) { $captured = $c; break }
    } catch {}
    Start-Sleep -Milliseconds 1500
  }
  if ($captured) {
    $script:ConvUrl = $captured
    Write-Warning "已捕获会话链接: $captured"
  } else {
    Write-Warning "30s 内没捕获到 /app/<id> 链接——本轮照常记录；下一轮会用会话浏览标签认领"
  }
}

# ---- 等待生成完成 ----

$stWait = Get-PageState $WB_SESSION
$baseUq = if ($stWait) { [int]$stWait.uq } else { 1 }
$script:Answer = $null
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$tStart = Get-Date
$lastLen = -1; $stableCount = 0; $iter = 0
# 等待期最小打扰（2026-10-19 实测：窗口最小化后回答仍会写入 DOM）
# → 默认不抢焦点；仅当连续 120s 完全没有进展时才轻激活一次（最多 2 次）
$lastProgress = Get-Date
$lastMr = if ($stWait) { [int]$stWait.mr } else { 0 }
$stallNudges = 0
while ((Get-Date) -lt $deadline) {
  $iter++
  Start-Sleep -Milliseconds 2200
  $st = Get-PageState $WB_SESSION
  if (-not $st) { continue }
  if ([int]$st.mr -ne $lastMr) { $lastMr = [int]$st.mr; $lastProgress = Get-Date }
  if (((Get-Date) - $lastProgress).TotalSeconds -gt 120 -and $stallNudges -lt 2) {
    $stallNudges++
    Write-Warning "等待生成超过 120s 无进展，轻激活一次以刷新渲染（第 $stallNudges 次）"
    [void](Force-ActivateBrowser)
    $lastProgress = Get-Date
  }
  if ([int]$st.mr -ge [int]$st.uq -and [int]$st.uq -ge 1) {
    if (-not $st.stop) {
      $md = Get-LastAnswerMarkdown $WB_SESSION
      $len = if ($md) { $md.Length } else { 0 }
      if ($len -gt 0 -and $len -eq $lastLen) {
        $stableCount++
        if ($stableCount -ge 3) {
          # 交叉确认：再等一轮并复查长度与生成指示，防止生成中途 stop 短暂消失导致截断
          Start-Sleep -Milliseconds 1500
          $md2 = Get-LastAnswerMarkdown $WB_SESSION
          $stc = Get-PageState $WB_SESSION
          if ($md2 -and $md2.Length -ge $len -and $stc -and -not $stc.stop) { $script:Answer = $md2; break }
          $stableCount = 0
        }
      } else { $stableCount = 0 }
      $lastLen = $len
    }
  }
}
$elapsedWait = [int]((Get-Date) - $tStart).TotalSeconds

if (-not $script:Answer) {
  Write-Warning "生成超时（已等 ${elapsedWait}s），最后再读一次…"
  $stF = Get-PageState $WB_SESSION
  if ($stF -and [int]$stF.mr -ge [int]$stF.uq -and [int]$stF.uq -ge 1) {
    $md = Get-LastAnswerMarkdown $WB_SESSION
    if ($md) { $script:Answer = $md }
  }
}
if (-not $script:Answer) { Fail 9 "生成超时（$TimeoutSec s）且无可用回答；会话链接已记录，重跑同一命令即可续聊" }

# ---- 写文档 + 固化状态 ----

$anchorFinal = if ($script:ConvUrl) { $script:ConvUrl } else { $anchor }
if (-not $anchorFinal) { $anchorFinal = "unknown" }
Ensure-Dir (Split-Path $DocPath -Parent)
$round = (Get-DocRoundCount $DocPath) + 1
if (-not (Test-Path $DocPath)) {
  Write-DocHeader -Path $DocPath -DocTitle $Title -S $Session -Curl $anchorFinal -Acct $acctEmail -Mode $modeActual
  $round = 1
}
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$entry = "`r`n## Q$round $ts`r`n**Q:** $Question`r`n`r`n**A:**`r`n$($script:Answer)`r`n"
[System.IO.File]::AppendAllText($DocPath, $entry, (New-Object System.Text.UTF8Encoding($false)))
Update-DocMarker -Path $DocPath -S $Session -Curl $anchorFinal -Acct $acctEmail -Mode $modeActual -Rounds $round

$hist = @()
if ($state -and $state.convHistory) { $hist = @($state.convHistory) }
if ($state -and $state.convUrl) {
  $oc = Get-CanonicalConvUrl $state.convUrl
  if ($oc -and (Get-ConvId $oc) -ne (Get-ConvId $anchorFinal) -and $hist -notcontains $oc) { $hist += $oc }
}
Write-DiscussState $Session (@{
  session = $Session; convUrl = $anchorFinal; convHistory = $hist; docPath = $DocPath
  title = $Title; groupTitle = $GroupTitle; rounds = $round
  account = $acctEmail; accountIndex = $acctIndex; mode = $modeActual
  createdAt = $(if ($state -and $state.createdAt) { $state.createdAt } else { (Get-Date).ToString("s") })
  updatedAt = (Get-Date).ToString("s")
})

Write-Warning "Q&A 已追加: $DocPath (Q$round) | 会话: $anchorFinal | 模式: $modeActual"
Release-Lock
$script:Answer
