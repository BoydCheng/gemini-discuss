# Gemini 网页端 UI 事实笔记（维护用）

> 用途：`gemini-discuss` skill 的界面依据。均为 2026-10-15 实测（Edge + Kimi WebBridge v2.0.15，Gemini Web 2026-10 版 UI，简体中文界面）。**改版时以本机实测更新本文件与脚本。**
> 本文件已去除账号/会话等个人信息，只保留可复用的界面事实。

## 1. 账号与 URL 结构

| 项 | 实测结果 |
|---|---|
| 多账号 | 浏览器登录多个 Google 账号；Gemini 用 `/u/<N>/` 路径区分 |
| 新对话页 | `https://gemini.google.com/u/<N>/app` |
| 会话页 | `https://gemini.google.com/u/<N>/app/<convId>`，convId = 16 位 hex |
| 默认账号页 | `https://gemini.google.com/app`（不带 /u/N，使用浏览器默认账号；可能重定向到 /u/N/） |
| 账号识别 | `[aria-label*="Google 账号"]` 的文案含邮箱；侧栏底部 `sidenav-mavatar-footer` 显示昵称+订阅档 |

## 2. 模型 / 思考等级（模式选择器）

- 选择器按钮：`button.input-area-switch`
  - 按钮文本（去空格）：如 `Argon高点`；aria：`打开模式选择器，当前模式为“Argon 高点”`
- 打开菜单：对该按钮 `el.click()` 或 CDP 点击（均有效）
- 菜单结构（`gem-menu` → `gem-menu-item`；label 取 `.label`，副标 `.sublabel`）：
  - 模型（产品名，界面语言无关）：`3.5 Flash-Lite`（极速回答）/ `3.8 Flash`（全方位帮助）/ `3.1 Pro`（高级推理）/ `4 Argon`（复杂任务）
  - 分隔线 + `思考等级`（子菜单，**中文标签**）：`低点`（快速高效）/ `中等`（深度适中）/ `高点`（超级详尽）
  - Ultra 账号可能出现 `Deep Think`；非 Ultra 无此项（自动降级到最深可用）
- **交互真相（关键）**：
  1. 菜单 = roving tabindex：焦点项 `tabindex=0` + `class=active`；其余 `tabindex=-1`
  2. **鼠标点击菜单项无效**（trusted 全事件序列也不生效；多次复现）
  3. **键盘导航有效**：`ArrowDown/Up` 移动焦点，`ArrowRight` 进子菜单，`Enter` 提交
  4. **键盘前提：浏览器窗口必须前台**（否则 CDP 按键不投递，无任何报错）
  5. 子菜单开合受 hover 影响；用键盘操作不受影响
- 操作序列：`点击选择器打开 → ArrowDown ×N 到目标（模型项）→ Enter`；子菜单：`…到 思考等级 → ArrowRight → ArrowDown ×M 到目标档 → Enter`
- 选择后按钮文本变为 `模型缩写+档位`（如 `Argon高点`）；**新对话页的默认档位可能不是最高档，需每次创建时确保**

## 3. 输入与发送（最难的部分）

| 项 | 结论 |
|---|---|
| 编辑器 | `div.ql-editor[contenteditable]`（Quill 系），可中文填充 |
| 发送键 | `button[aria-label="发送"]`（在 `.send-button-container` 内，**有输入才渲染**，动画延迟 ~0.5-1.5s） |
| Enter 发送 | 编辑器聚焦时 CDP 真实 Enter 键（keyDown 带 `text:"\r"`）+ keyUp → 立即发送 |
| 发送前闸门 | **必须等发送键出现**（出现 = 应用已登记输入；不出现 = 页面处于降级态） |
| 降级态 | 页面在"隐藏/后台"时加载会导致：输入区不注册输入、会话内容不渲染、发送键永不出现、模式选择器不渲染 → 必须**可见重载** |
| 页面就绪信号 | `input-area` 含 `children-ready`；已有会话 `user-query` 数量>0；模式选择器在场 |
| 发送确认 | `user-query` 数量 +1（DOM）；**绝不能盲重试**（实测盲重试导致同一问题发出 3 次） |
| 降级恢复 | 强制激活（AttachThreadInput 组合拳）+ 重载会话 URL（保持可见），再重试 |
| 窗口激活 | 先 `Page.bringToFront`（标签成为窗口活动标签 → 标题含 `Gemini`）→ 按标题找窗口 → `AttachThreadInput + BringWindowToTop + SetForegroundWindow`（可绕过 Windows 前台锁）；仍失败才用最小化+还原 |
| 可见性观察 | `document.visibilityState` / `document.hasFocus()`；窗口被抢焦点后 vis 变 hidden；加载/发送关键期需反复激活 |

## 4. 生成完成与答案读取

| 项 | 结论 |
|---|---|
| 生成中信号 | `.stop-button`（发送后出现，完成消失）；快问快答时可能一闪而过 |
| 完成判定 | 新 `model-response` 出现 + 文本长度连续两次一致 + stop 消失 |
| 回答节点 | `model-response`（当前轮 = 最后一个）；正文在 `.markdown` 内 |
| 读取方式 | **DOM→Markdown 重建**（验证有效）：表格→`\| … \|`、代码块→围栏、列表、加粗、链接 |
| 代码语言 | 代码块头部 `div.code-block-decoration span`（如 `C`）；正文 `pre > code[data-test-id=code-content]` |
| 思考过程 | DOM 中存在 thought 相关元素；未抓取（v1 不需要） |
| 实测耗时 | 简单结构化问答（表格+代码，400字内）：~5 秒；追问一句话：~5-15 秒 |

## 5. 侧栏与会话列表（-ListChats / -Attach 依据）

- 会话项 = `a[href="/u/<N>/app/<id>"]`（可见时）；标题取 `innerText`
- **列表是"展开时懒创建"的**：侧栏折叠时 DOM 里没有链接
- 展开动作：点击 `button[aria-label="主菜单"]`（**副作用在隐藏态也有效**；展开后列表立即出现）
- 展开态标记：存在 `button[aria-label="关闭边栏"]`；折叠态可能同时存在多个侧栏组件（`打开边栏`/`关闭边栏` 并存），不要只靠按钮判断展开
- 列表内容是异步水合的：展开后仍需轮询等待链接出现（可见时更快）

## 6. 其他事实

- Kimi WebBridge 扩展装在 **Edge**（`%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Extensions\` 下）
- webbridge `fill` 的 contenteditable 实现 = focus + 全选 + `execCommand('insertText')`（回退 textContent+input 事件）
- 通过 webbridge `cdp` 可用：`Runtime.evaluate`、`Page.bringToFront`、`Input.dispatchKeyEvent`、`Input.dispatchMouseEvent`、`Input.insertText`
- `Browser.getWindowForTarget` 不可用（扩展侧不支持浏览器级方法）
- 页面加载时若标签在后台：内容/输入区初始化不完整（多次复现）——"保持可见"是操作前提
