---
name: gemini-discuss
description: |
  通过真实浏览器（Edge + Kimi WebBridge daemon）用你的 Gemini 登录态与网页版 Gemini（4 Argon + 高点思考档）进行**多轮讨论**，每轮 Q&A 自动追加到同一个 Markdown 文档并带回对话。触发词：用Gemini讨论、问一下Gemini、和Gemini聊聊、帮我问Gemini、问问Gemini的意见、和网页版Gemini交互、继续问Gemini、追问Gemini、用Gemini深度思考。
metadata:
  version: "1.0.0"
---

# Gemini 讨论（gemini-discuss）

## 用途

在真实浏览器（Edge，你本人的 Gemini 登录态）里向网页版 Gemini 提问、读取完整回答（DOM→Markdown 重建，表格/代码/列表保真），并把每轮 Q&A 追加到同一个 Markdown 文档存档。相当于把网页版 Gemini 当作一个"外部讨论对象"。

**账号**：默认**自动检测**浏览器当前登录的 Gemini 账号（首次运行记录到 state，之后沿用）；多账号时用 `-Account <email>` 指定。

**模型策略**：每次新讨论自动确保使用**当前账号可用的最深配置**（例如 `4 Argon` 模型 + `高点` 思考档，选择器显示 `Argon高点`）。没有 Deep Think（Ultra 专属）时自动降级到最深可用项，并在文档头记录实际模式。

---

## 身份模型（先读懂这段，否则一定会开出一堆重复对话）

> **一个讨论 = 一条 Gemini 会话 URL（`https://gemini.google.com/u/<N>/app/<id>`）。**
> webbridge 的 `session` 名和浏览器标签组**只是执行通道**，标签丢了、浏览器重启了都不影响"同一个讨论"。

- 会话 URL 由脚本自动捕获并持久化在两处：
  - `%LOCALAPPDATA%\gemini-discuss\state\<session>.json`（运行状态，SSOT；含账号索引、模式、轮数）
  - 文档头的 `<!-- gemini-discuss: session=... conv=... -->` 注释（可移植备份）
- **续聊时脚本会先读这两个锚点，再按 URL 把标签找回来或重开**。所以**永远不需要**为了"回到原对话"而做任何特殊操作。
- 脚本会自动写文档头（含链接/账号/模式）。**不要手写文档头、不要手改 session 名、不要改文档文件名。**

---

## 决策流程（每次调用前照做）

```
① 先查现状：      pwsh -File <skill>\scripts\ask-gemini.ps1 -Status
② 已有该话题 →    续聊：不带 -New，带上原 -Session 与 -DocPath
③ 确实是新话题 →  新建：-New（脚本会捕获新链接并记录）
④ 要接管"已存在的某条对话"（你手动开的 / 历史上被撕碎的）→ 用 -ListChats 找 → 用 -Attach 挂回来
```

**判断"是不是新话题"的标准**：同一个讨论线（同一份文档、同一批上下文）→ 是同一个话题。只是"换个问法/再深入一点"→ 仍然是同一个话题 → **继续追问，不要 -New**。

### 首轮（新话题）

```powershell
pwsh -File "$env:USERPROFILE\.config\opencode\skills\gemini-discuss\scripts\ask-gemini.ps1" `
  -Question "你的问题（支持中文）" `
  -Session "任务slug" `
  -Title "讨论标题" `
  -New `
  -DocPath "D:\MyProjects\...\docs\gemini_qa\<slug>.md"
```

### 后续轮次（同一话题，**这是最常用的形态**）

**和首轮完全一样，只去掉 `-New`**：

```powershell
pwsh -File "$env:USERPROFILE\.config\opencode\skills\gemini-discuss\scripts\ask-gemini.ps1" `
  -Question "追问的内容" `
  -Session "任务slug" `
  -DocPath "D:\MyProjects\...\docs\gemini_qa\<slug>.md"
```

脚本会：读锚点 → 在**原会话**里追问 → 追加 `## Q<n>` 到**同一份文档** → stdout 只输出回答全文。
`-DocPath` 不传也行（会复用 state 里记录的文档），但**显式传更稳**。

> ⚠️ **中文问题请通过变量或文件传递**（避免多层命令行转义）：
> ```powershell
> $q = [IO.File]::ReadAllText('q.txt', [Text.Encoding]::UTF8).Trim()
> pwsh -File ...ask-gemini.ps1 -Question $q -Session ...
> ```

### 接管"已存在的对话"（-ListChats / -Attach）

```powershell
# ① 列出账号里的会话（只读，不提问、不改文档）
pwsh -File ...\ask-gemini.ps1 -ListChats -Limit 30
#    输出：标题 / 会话 id /（若已锚定）← 已锚定: <session>

# ② 挂到某个讨论（标题关键字 / 完整链接 / 裸 id 都行）
pwsh -File ...\ask-gemini.ps1 -Attach "RK3399读取优化建议" -Session rigol-perf
pwsh -File ...\ask-gemini.ps1 -Attach <conversationId> -Session rigol-perf
```

- **不带 `-Question` = 只绑定**：写好 state 与文档标记后退出（stdout 输出该会话链接）
- **带 `-Question` = 绑定 + 立刻追问**，直接落在那条原对话里（**带完整历史上下文**）
- 标题匹配到多条时**会拒绝**并列候选让你选（不会瞎猜）

---

## Gemini 网页端的操作现实（必读——这些不是脚本能绕过的）

实测（Edge + Gemini Web 2026-10 版 UI）：

| 现实 | 对使用的影响 |
|---|---|
| **页面必须在"可见"状态下加载/交互**：窗口被遮挡/最小化时加载的页面会进入降级态（会话内容不渲染、输入不注册、发送键不出现、模式选择器不渲染） | 脚本会在关键节点自动激活浏览器窗口（`AttachThreadInput` 组合拳，用户正在其他窗口打字时也能抢回前台）。运行期间**浏览器会短暂弹到前台**，这是 Gemini 网页的硬要求，不是脚本选择 |
| **CDP 键盘/鼠标事件在页面不可见时被静默丢弃** | 脚本等待"可见+就绪"后才输入；你不需要手动准备什么 |
| **模型/思考档菜单只认真实键盘**（roving tabindex；合成点击无效） | 脚本用键盘导航（方向键+Enter）设置模式；仅在模式需要变更时执行 |
| **「发送」靠 CDP Enter（真实按键）**；发送结果用会话记录（user-query 计数）核实 | **绝不盲重试**——盲目重试可能把同一问题发出多次。脚本失败时会先重载核实，再决定是否重试 |
| **侧栏会话列表折叠时不渲染**；展开动作（点「主菜单」）在隐藏态也有效 | `-ListChats` / `-Attach` 先自动展开侧栏 |
| 后台运行 vs 前台 | **等待生成可以完全后台**（实测：发送成功后最小化窗口，回答照常写入 DOM 并完成）；只有**打开页面 / 设置模式 / 按下发送**三个短时刻需要前台 |

**界面语言：需要简体中文。** 脚本按中文标签定位（发送键、模式菜单的「思考等级/低点/中等/高点」、侧栏「主菜单」等）；英文界面暂未适配。

---

## 硬约束（违反 = 制造重复对话，历史上就是这么坏的）

| 禁止 | 原因 / 正确做法 |
|---|---|
| **发送"看起来失败"时立刻重跑同一条命令** | 可能实际已发出（只是页面没刷新）。脚本内部会先重载核实再决定；人工介入时也先用 `-Status`/浏览器核对会话后再重试 |
| **每轮改 session 名**（`xaxis` → `xaxis2`） | 会开出多条重复对话。同一个话题永远用同一个 `-Session` |
| **每轮改 `-Title` / `-GroupTitle`** | 会在浏览器里多长出一个标签分组。分组名和标题一旦建立就粘在 state 里，别动 |
| **同一个话题换文档**（`wedge.md` → `wedge2.md`） | 档案被撕碎。续聊必须复用同一份文档 |
| **并发调用 / 超时后立即重发** | 会双开并互相写坏同一对话。脚本有锁（`exit 12`），别绕 |
| **手写文档头 / 手改文档里的 `conv=` 标记** | 会破坏锚点，导致下一轮认不出原对话 |
| **换账号话题混用** | 会话绑定在具体 Google 账号上（URL 带 `/u/<N>/`）。不要中途改账号续聊同一话题 |
| **绕过脚本手工 curl webbridge 做多轮** | 手工路径**没有状态**，必然开新对话。脚本坏了就报错，不要自己发明流程 |

---

## 常用参数

| 参数 | 说明 |
|---|---|
| `-Question` | 问题正文（必填，除非 `-Status`/`-ListChats`/`-Attach`） |
| `-Session` | 讨论 slug。不传时：有 `-DocPath` 就从文档名推导；否则复用当前工作区**最近用过**的讨论 |
| `-DocPath` | Q&A 文档。不传时优先复用 state 里记录的（跨天不拆文件） |
| `-Title` | 文档标题（仅首轮写入；之后从 state 粘住，别改） |
| `-New` | 声明"新讨论"。已有锚点时会被拒绝（`exit 10`） |
| `-ForceNew` | 确认放弃原线程、开新的（旧链接归档进 `convHistory`） |
| `-Status` | 只读列出所有讨论（session / 轮数 / 会话链接 / 账号 / 模式），不碰浏览器 |
| `-ListChats` | **只读**列出账号侧栏会话（标题 / id / 本地锚定情况） |
| `-Attach` | 把**已存在的会话**挂到当前讨论：标题关键字、完整链接或裸 id。不带 `-Question` 时只绑定 |
| `-Limit` | `-ListChats` 显示条数，默认 30 |
| `-Account` | 目标 Google 账号 email。**留空 = 自动检测当前登录账号**（默认）；多账号时指定 |
| `-Model` / `-Thinking` | 首选模型/思考档（默认 `4 Argon` / `高点`；菜单中缺失时按内置偏好列表自动降级） |
| `-TimeoutSec` | 单轮生成超时，默认 600 |
| `-MaxRecover` | 单轮内用会话 URL 重开标签的最大次数，默认 2 |
| `-CloseExtras` | 清理该 session 内不属于本讨论的 gemini 标签 |
| `-Daemon` | daemon 地址。**留空即自动探测**（读 `~/.kimi-webbridge/daemon.addr` → 退回 10086） |

---

## 退出码表（脚本真实会返回的；**按表行动，不要自己猜**）

| 码 | 含义 | 你该做什么 |
|---|---|---|
| 0 | 成功 | — |
| 3 | webbridge daemon 不可用 | 跑 `"%USERPROFILE%\.kimi-webbridge\bin\kimi-webbridge.exe" start` 后重试**同样**命令 |
| 5 | 页面未就绪（登录墙/加载失败/改版） | 检查浏览器；稍后重跑同一条命令 |
| 6 | 有锚点但打不开会话页 / 会话为空 | **不要 `-New`**。先 `-Status` 看链接；确认浏览器能打开该链接 |
| 7 | 填入问题失败（发送键闸门超时） | 页面降级且恢复失败。稍后重跑同一条命令 |
| 8 | 发送失败（**已核实**没有新提问） | 检查浏览器状态后重跑；不要连续重试 |
| 9 | 生成超时且无回答 | 会话链接已记录，重跑同一条命令即可续聊 |
| 10 | 已有讨论线程，拒绝新建 | 去掉 `-New` 重跑；确实要新线程才加 `-ForceNew` |
| 11 | 发送前校验：页面不是锚定会话 | 标签被手动导航走了。不要 `-New`，用 `-ConvUrl` 指回原链接 |
| 12 | 同一 session 已有进程在跑 | 等它跑完，**不要**并发/不要换 session 名绕开 |
| 13 | 参数/文档冲突（含 Attach 匹配不唯一/找不到） | 按报错信息修正参数 |
| 14 | 未找到/未登录目标账号 | 先在浏览器登录 Google 账号；多账号时用 `-Account` 指定 |

---

## 前置条件

- Windows + PowerShell 7
- Kimi WebBridge daemon 运行中（`kimi-webbridge start`）。地址**自动探测**
- 已在 **Edge**（或 Chrome/Brave/Vivaldi）登录 Gemini；**界面语言为简体中文**
- **运行期间浏览器窗口会被脚本短暂激活**（Gemini 网页硬要求，见上文"操作现实"）
- ⚠️ daemon 扩展槽位只能被一个浏览器实例占用；出现 `slot held by` 日志时关掉多余实例

## 文档存放规则

- **默认位置**：当前工作区 `docs/gemini_qa/<日期>-<session>.md`（自动创建目录）
- **项目规则优先**：若工作区 AGENTS.md 规定了文档目录，用 `-DocPath` 显式指定
- 同一话题所有轮次自动追加到同一份文档（`## Q<n>` 递增）
- 文档头由脚本写（标题 + `gemini-discuss` 注释 + 账号/模式/链接行），**AI 不要手写**
- 用户明确要求关闭标签组时调用 webbridge `close_session`；**不主动关闭**

## 文档格式（脚本自动生成）

```markdown
# Gemini 讨论：<标题>（<日期>）

<!-- gemini-discuss: session=<s> conv=https://gemini.google.com/u/<N>/app/<id> account=<email> mode=4 Argon 高点 updated=<ts> rounds=<n> -->
- 会话: <s> | 账号: <email> | 模式: 4 Argon 高点 | 链接: https://gemini.google.com/u/<N>/app/<id>

## Q1 <时间戳>
**Q:** <问题>

**A:**
<Gemini 回答全文（Markdown 重建：表格/代码块/列表保真）>
```

## 答案读取与完成判定（机制说明）

- 回答 = 最后一个 `model-response` 的 `.markdown` 子树 → **DOM→Markdown 重建**（`| 表格 |`、``` 代码块```、列表、加粗；代码块语言取自 `code-block-decoration`；公式优先取 `data-math` 还原为 `$…$`，避免 KaTeX 双层文本重复）
- 完成判定 = 新回答出现（`model-response` 数 ≥ `user-query` 数）且文本长度连续两次一致且停止按钮消失
- 超时兜底只在"本轮确有回答"时才读取（防止把上一轮答案误当本轮）

## 维护：改脚本后**必须**跑自检

```powershell
# 一条命令跑完：静态检查 + 检查器自证 + 离线行为回归（不碰浏览器）
pwsh -File "<skill>\tools\selftest.ps1"
# 文档体检（离线）：标记/段落/重复提问检测
pwsh -File "<skill>\tools\verify-docs.ps1" -Roots <项目根>
```

**AI 不要"顺手改脚本"**：优先用现有参数（`-Status` / `-ListChats` / `-Attach` / `-ConvUrl` / `-ForceNew` / `-CloseExtras`）解决问题。
确需改代码时，改完**必须**跑 `selftest.ps1` 且全部 PASS 才算完成。

**验证纪律**：不要拿"它记不记得上文"当证据（网页端有对话记忆）；这一轮是否落进目标会话，以 URL 锚点 + 会话记录（user-query 计数）为准。

## 限制

- 依赖 Gemini 网页 DOM：`.ql-editor`（输入）、`button[aria-label="发送"]`、`.stop-button`、`model-response`、`button.input-area-switch`（模式）。UI 改版时需同步更新脚本与 UI 事实笔记（`notes\ui-facts.md`）
- 仅文本问答；不做图像/文件上传
- **需简体中文界面**；英文界面暂未适配
- **后台运行限制**：页面加载与交互需要"可见"；发送后的等待阶段可以后台
- 模式复核是尽力而为：会话页在隐藏态加载时选择器可能不渲染 → 脚本沿用记录值并告警（会话创建时已确保过模式，且 Gemini 会话保持其自身模式）
- 新版 UI 下模式可能"已切换但选择器文本不刷新"（切换 RPC 200，picker 仍显示旧值）→ 告警 `模式确认: 未校验`，问答不受影响；详见 `notes\ui-facts.md`
- 首屏加载慢的环境（冷加载 40s+）首次可能 `exit 5/6`：重跑**同一条**命令即可，脚本页面等待上限已放宽到 90-120s
- Deep Think 为 Ultra 专属；非 Ultra 账号最深 = `4 Argon + 高点`
