# gemini-discuss —— 用 OpenCode 跟网页版 Gemini 多轮讨论

把网页版 **Gemini（4 Argon + 高点思考档）** 当作一个外部讨论对象：提问 → 自动抓取完整回答（表格/代码块保真）→ 追加到同一份 Markdown 文档；同一话题可无限续聊。

> 版本：v1.0.0-share（2026-10-19）｜适用：Windows + OpenCode/OpenChamber + Edge

---

## 依赖

| 依赖 | 说明 |
|---|---|
| Windows + **PowerShell 7** | `pwsh` 必须在 PATH（Windows 自带的是 5.1，脚本需要 7） |
| **Edge**（或 Chrome/Brave/Vivaldi） | 其中一个浏览器登录 Gemini |
| **Kimi WebBridge 扩展 + daemon** | 官方页面：<https://www.kimi.com/products/kimi-webbridge>（中文）。安装扩展后启动 daemon：`"%USERPROFILE%\.kimi-webbridge\bin\kimi-webbridge.exe" start` |
| Gemini 界面语言 | **简体中文**（脚本按中文标签定位；英文界面暂未适配） |

> 脚本只通过本机 daemon 驱动你自己的浏览器，不发送任何数据到第三方服务。

## 安装

把 `gemini-discuss` 整个文件夹放到以下**任一**位置：

```
~/.config/opencode/skills/gemini-discuss/     ← OpenCode 官方全局位置（推荐）
~/.agents/skills/gemini-discuss/              ← 兼容位置（也会被加载）
```

放好后新开一个 OpenCode/OpenChamber 会话，技能列表中应出现 `gemini-discuss`。也可以不装技能、直接命令行调用脚本（见下）。

## 快速开始

```powershell
$skill = "$env:USERPROFILE\.config\opencode\skills\gemini-discuss"

# 先确认环境（不碰浏览器）
pwsh -File "$skill\scripts\ask-gemini.ps1" -Status

# 首轮（新话题）：-Account 留空 = 自动检测浏览器当前登录的 Gemini 账号
$q = "用表格对比 RS-232 / RS-485 / TTL 串口，并给一句话总结。"
pwsh -File "$skill\scripts\ask-gemini.ps1" -Question $q -Session uart-basics -New -Title "串口对比"

# 追问（同一话题）：去掉 -New，其余不变
$q2 = "再补一句：RS-485 半双工收发切换要注意什么？"
pwsh -File "$skill\scripts\ask-gemini.ps1" -Question $q2 -Session uart-basics

# 查看已有讨论 / 列出账号里的会话 / 接管某条已有会话
pwsh -File "$skill\scripts\ask-gemini.ps1" -Status
pwsh -File "$skill\scripts\ask-gemini.ps1" -ListChats
pwsh -File "$skill\scripts\ask-gemini.ps1" -Attach "会话标题关键字" -Session uart-basics
```

回答会直接打印到 stdout，同时追加到 `<当前目录>\docs\gemini_qa\<日期>-<session>.md`（可用 `-DocPath` 指定）。

**多账号**：默认自动检测浏览器当前登录的账号；要指定别的账号用 `-Account someone@gmail.com`。
**中文问题建议走变量/文件**（避免命令行转义）：`$q = [IO.File]::ReadAllText('q.txt',[Text.Encoding]::UTF8).Trim()`。

## 使用须知（重要）

1. **运行时会短暂激活浏览器窗口**——这是 Gemini 网页的硬要求：页面在后台加载会进入降级态（内容不渲染、输入不生效），脚本必须让标签可见才能工作。**发送成功后等待生成时完全不需要前台**（实测：最小化窗口后回答照常写入并完成），脚本不会再抢焦点。
2. **发送"看起来失败"时不要立刻重跑**：可能实际已发出（只是页面没刷新）。脚本内部会先重载核实；手动重试前先用 `-Status` 或浏览器核对。
3. 同一话题**始终用同一个 `-Session`**，不要每轮改名字/标题/文档，否则会开出重复对话。
4. 扩展槽位只能被一个浏览器实例占用；若日志出现 `slot held by`，关掉多余的浏览器实例。
5. **模型/思考档可能"已切换但选择器不刷新"**：部分环境下新版 Gemini 网页的 picker 文本不变，脚本告警 `模式确认: 未校验`，问答不受影响。
6. **首屏加载慢的环境**首次可能 `exit 5/6`，重跑同一条命令即可（脚本内部页面等待上限已放宽到 90–120s）。
7. **免费账号会自动跳过模型选择**：脚本检测到页面「升级」入口（无 Pro 权限）时不再尝试切换 `4 Argon`/`高点`。

## 自检（改脚本后必跑）

```powershell
pwsh -File "$skill\tools\selftest.ps1"        # lint + 检查器自证 + 7 个离线用例（不碰浏览器）
pwsh -File "$skill\tools\verify-docs.ps1" -Roots <项目根>   # 文档体检（离线）
```

## 目录结构

```
gemini-discuss/
├─ SKILL.md                 # 技能说明（AI 读取；含全部参数/退出码/约束）
├─ scripts/ask-gemini.ps1   # 主脚本
├─ tools/                   # selftest / lint / verify-docs
└─ notes/ui-facts.md        # 网页 UI 事实（改版维护用）
```

## 常见问题

| 现象 | 处理 |
|---|---|
| `exit 3` | daemon 没起：`kimi-webbridge start` |
| `exit 14` | 浏览器没登录 Gemini，或 `-Account` 指定的账号不在该浏览器 |
| `exit 7` / `exit 8` | 页面降级/发送未生效：等几秒重跑同一条命令（脚本会先核实，不会重复提问） |
| 技能列表里没有 | 确认文件夹层级是 `.../skills/gemini-discuss/SKILL.md`，然后重启会话 |
