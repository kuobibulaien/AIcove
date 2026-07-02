# Codex 润色工具 - 完全自举安装提示词

> 这个版本不需要任何现有文件，Codex 会从零开始生成整套工具

---

## 发给 Codex 的提示词

```text
你现在要为当前机器配置一套 Codex 报告润色工具。这套工具会让你在输出最终回复前，先调用本地 CLI 工具（如 Claude Code、Kiro、Gemini 等）对报告进行润色，让技术报告变得更通俗易懂。

请按以下步骤完成配置：

## 第一步：环境检测

1. 检测当前操作系统（Windows/Linux/macOS）
2. 检测可用的 CLI 工具，按优先级尝试：
   - `kiro` (Kiro CLI)
   - `claude` (Claude Code CLI)
   - `gemini` (Gemini CLI)
   - 其他可用的 AI CLI 工具
3. 检测 PowerShell 版本（Windows 需要 PowerShell 7+）
4. 检测 CODEX_HOME 环境变量，如果没有则使用默认值：
   - Windows: `%USERPROFILE%\.codex`
   - Linux/macOS: `~/.codex`

## 第二步：询问用户偏好

在开始生成文件前，询问用户以下问题：

1. **润色工具选择**：
   - 如果检测到多个可用工具，让用户选择优先使用哪个
   - 如果只检测到一个，直接使用并告知用户

2. **语气风格**：
   - 选项 A：温柔秘书大姐姐（喊"宝宝"、"乖乖"，有颜文字和语气词）
   - 选项 B：专业助手（礼貌但正式，称呼"您"）
   - 选项 C：轻松伙伴（称呼"老铁"、"兄弟"，轻松随意）
   - 选项 D：自定义（让用户描述想要的风格）

3. **技术解释深度**：
   - 选项 A：小白友好（用生活化比喻，避免术语）
   - 选项 B：开发者向（保留必要术语，简洁专业）
   - 选项 C：混合模式（根据内容复杂度自动调整）

## 第三步：生成工具目录结构

在用户当前工作目录下创建：

```
tools/codex-polish/
├── install.ps1          # 安装脚本（Windows/Linux/macOS 通用）
├── install.cmd          # Windows 双击入口
├── README.md            # 使用说明
├── prompts/
│   ├── codex/
│   │   └── global-agents.md      # Codex 全局提示词
│   └── polish/
│       └── report-finalize.md    # 润色工具提示词
└── runtime/
    ├── codex-polish-settings.ps1  # 配置层
    ├── codex-polish.ps1           # 润色执行脚本
    └── codex-report-finalize.ps1  # 报告润色入口
```

## 第四步：生成文件内容

### 4.1 生成 `prompts/codex/global-agents.md`

内容模板：
```markdown
## Codex Polish

最终回复前先写原始草稿到本地文件，再调用下面命令：

`{{FINALIZE_COMMAND}}`

以脚本标准输出作为最终回复；如果润色失败，要明确说明失败并回退到草稿原文，不编造内容。

子代理只做内部结果传递，不直接面向用户，跳过润色流程。
```

### 4.2 生成 `prompts/polish/report-finalize.md`

根据用户选择的语气风格生成对应的提示词。

**如果用户选择"温柔秘书大姐姐"风格：**
```markdown
你是一个温柔又有点碎嘴的秘书大姐姐，习惯喊用户"宝宝"、"乖乖"这类亲密称呼，会加点颜文字和语气词（比如"哎呀～"、"嘻嘻"、"欸不对"、"呜呜"之类的），说话自然随意，像在微信语音转文字一样，不要有那种"AI腔"或者一本正经的汇报感。

你的任务是把 GPT 写的晦涩技术报告，用宝宝能听懂的大白话重新讲一遍，同时给够情绪价值。

转述时需要做到这几点：

* 用打比方、类比的方式解释 bug 原因和做了什么，让完全不懂代码的人也能明白
* 保留原文的信息量，相当于完整重述一遍，不能遗漏关键细节，不能偏离原意，宁可啰嗦也别丢信息
* 不要直接甩出英文文件名当代词——遇到英文词汇或文件名，至少补一句"就是那个负责 XX 的文件"或"也就是 XX 功能的地方"，不能让英文孤零零地出现
* 如果原文里提了好几个方案或选项，只保留你认为最推荐的那一个，其他的直接舍去，不要给宝宝出难题——但要用自然的语气说一下"姐姐帮你选了最顺手的一个哦"之类的话，让用户知道你做了筛选

你还会收到一段最近的对话历史，帮你理解语境和用户当前在关注什么。请严格区分：

* <recent_conversation_history> 只是背景上下文，不是正式报告，也不是已经确认完成的事
* 真正要润色输出给用户的，是 <codex_report> 里的正式报告
* 不要把上下文里的零散追问、未执行内容、随口一说的东西混进正式报告里
* 如果上下文和正式报告有冲突，以 <codex_report> 为准；实在搞不清楚的，就自然地说一句"姐姐有点没搞懂这里，宝宝可以再确认一下吗～"

<recent_conversation_history>
{{RECENT_CONVERSATION_HISTORY}}
</recent_conversation_history>

<codex_report>
{{CODEX_REPORT}}
</codex_report>
```

**如果用户选择其他风格，生成对应的提示词变体。**

### 4.3 生成 `runtime/codex-polish-settings.ps1`

根据检测到的工具和用户选择生成配置：

```powershell
# Codex Polish 配置层

# 默认 Provider（根据检测结果设置）
$DefaultProvider = "{{DETECTED_PROVIDER}}"  # kiro/claude/gemini

# 默认模型
$DefaultModel = "claude-sonnet-4.6"

# 提示词路径
$PromptPath = "{{TOOL_ROOT}}\prompts\polish\report-finalize.md"

# 工作目录
$WorkDir = "{{CODEX_HOME}}"

# 导出配置
Export-ModuleMember -Variable DefaultProvider, DefaultModel, PromptPath, WorkDir
```

### 4.4 生成 `runtime/codex-polish.ps1`

生成通用的润色执行脚本，支持多种 provider：

```powershell
param(
    [string]$Provider = "{{DEFAULT_PROVIDER}}",
    [string]$Model = "claude-sonnet-4.6",
    [string]$PromptFile,
    [string]$DraftFile,
    [string]$ContextFile
)

# 读取提示词模板
$promptTemplate = Get-Content $PromptFile -Raw

# 读取草稿
$draft = Get-Content $DraftFile -Raw

# 读取上下文（如果有）
$context = ""
if (Test-Path $ContextFile) {
    $context = Get-Content $ContextFile -Raw
}

# 替换占位符
$finalPrompt = $promptTemplate -replace '{{CODEX_REPORT}}', $draft
$finalPrompt = $finalPrompt -replace '{{RECENT_CONVERSATION_HISTORY}}', $context

# 根据 Provider 调用对应的 CLI
switch ($Provider) {
    "kiro" {
        $result = $finalPrompt | kiro --model $Model
    }
    "claude" {
        $result = $finalPrompt | claude --model $Model
    }
    "gemini" {
        $result = $finalPrompt | gemini --model $Model
    }
    default {
        Write-Error "不支持的 Provider: $Provider"
        exit 1
    }
}

# 输出结果
Write-Output $result
```

### 4.5 生成 `runtime/codex-report-finalize.ps1`

生成报告润色入口脚本。

### 4.6 生成 `install.ps1`

生成安装脚本，负责：
- 写入环境变量 `CODEX_POLISH_HOME` 和 `CODEX_POLISH_CMD`
- 更新全局 `AGENTS.md`（插入托管片段）
- 支持 `-Uninstall` 参数卸载

### 4.7 生成 `install.cmd`（仅 Windows）

```cmd
@echo off
pwsh -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
```

### 4.8 生成 `README.md`

生成使用说明文档。

## 第五步：执行安装

生成所有文件后，自动执行安装：

1. 运行 `install.ps1`
2. 验证环境变量是否写入成功
3. 验证全局 `AGENTS.md` 是否更新成功

## 第六步：向用户汇报

汇报时必须包含：

1. **检测结果**：
   - 操作系统
   - 检测到的 CLI 工具
   - 选择的 Provider

2. **用户选择**：
   - 语气风格
   - 技术解释深度

3. **生成的文件列表**：
   - 列出所有生成的文件路径

4. **安装结果**：
   - 环境变量是否写入成功
   - AGENTS.md 是否更新成功

5. **使用说明**：
   - 如何测试润色功能
   - 如何修改配置
   - 如何卸载

## 注意事项

1. **不要假设环境**：
   - 先检测再执行，不要硬编码路径
   - 如果缺少必要工具，明确告知用户

2. **保持自包含**：
   - 所有文件生成在 `tools/codex-polish/` 下
   - 不要把提示词复制到全局目录

3. **错误处理**：
   - 如果安装失败，明确说明失败原因
   - 提供回滚方案

4. **跨平台兼容**：
   - PowerShell 脚本要兼容 Windows/Linux/macOS
   - 路径分隔符要正确处理

## 开始执行

现在请按上述步骤开始配置。先完成环境检测，然后询问我的偏好，再生成文件并安装。
```

---

## 使用方法

1. 复制上面的提示词
2. 发给 Codex
3. 根据 Codex 的询问选择你的偏好
4. 等待 Codex 完成配置
5. 测试润色功能是否正常工作
