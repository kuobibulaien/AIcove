# Codex 润色工具 - 自适应安装提示词

> 这个版本基于现有的文件结构，Codex 会自动适配不同环境（Windows/Linux/macOS）

---

## 使用说明

1. 把整个 `tools/codex` 文件夹分享给用户
2. 用户把下面的提示词复制给 Codex
3. Codex 会自动检测环境并完成配置

---

## 发给 Codex 的提示词

```text
你现在要为当前机器配置一套 Codex 报告润色工具。

这套工具的作用是：让你在输出最终回复前，先调用本地 CLI 工具（如 Kiro、Claude Code、Gemini 等）对报告进行润色，把技术报告变成通俗易懂的大白话。

工具文件已经准备好了，你需要根据当前机器的实际情况完成适配和安装。

## 第一步：环境检测

请先检测以下信息：

1. **操作系统**：
   - Windows / Linux / macOS

2. **可用的润色 CLI 工具**（按优先级检测）：
   - `kiro` (Kiro CLI) - **优先推荐**
   - `claude` (Claude Code CLI)
   - `gemini` (Gemini CLI)
   - 其他可用的 AI CLI 工具

3. **Shell 环境**：
   - Windows: PowerShell 版本（需要 7+）
   - Linux/macOS: bash/zsh + pwsh 是否可用

4. **Codex 全局目录**：
   - 检查 `CODEX_HOME` 环境变量
   - 如果没有，使用默认值：
     - Windows: `%USERPROFILE%\.codex`
     - Linux/macOS: `~/.codex`

5. **当前工具目录**：
   - 确认当前目录下是否存在 `install.ps1`
   - 确认 `prompts/` 和 `runtime/` 目录是否完整

## 第二步：工具选择和配置

### 2.1 选择润色工具

根据检测结果：

- **如果没有检测到任何 CLI 工具**：
  - 推荐用户安装 Kiro（最稳定、功能最全）
  - 询问用户："检测到你还没有安装润色工具，我推荐安装 Kiro。我可以帮你自动安装 Kiro CLI，你只需要在安装完成后登录一下就行。要我帮你装吗？"
  - 如果用户同意，执行 Kiro 安装命令（根据 OS 选择对应的安装方式）
  - 安装完成后提醒用户运行 `kiro login` 登录

- **如果检测到一个工具**：
  - 直接使用，并告知用户："检测到你已经安装了 [工具名]，我会用它来润色报告~"

- **如果检测到多个工具**：
  - 推荐使用 Kiro（如果有的话）
  - 告知用户："检测到你安装了 [工具列表]，我推荐用 Kiro（功能最全），你觉得呢？"
  - 等待用户确认

### 2.2 确认提示词模板

告知用户：

"工具自带了一个'温柔秘书大姐姐'风格的提示词模板（会喊你'宝宝'，用生活化比喻解释技术问题）。

如果你想用其他风格，可以稍后修改 `prompts/polish/report-finalize.md` 文件。

现在先用默认模板安装，可以吗？"

等待用户确认后继续。

## 第三步：生成适配脚本

根据检测到的环境，生成或修改以下文件：

### 3.1 更新 `runtime/codex-polish-settings.ps1`

确保配置文件中的 Provider 设置正确：

```powershell
# 默认 Provider（根据用户选择设置）
$DefaultProvider = "kiro"  # 或 claude/gemini

# 默认模型
$DefaultModel = "claude-sonnet-4.6"

# 提示词路径（支持项目级覆盖）
function Get-PromptPath {
    param([string]$ProjectRoot)
    
    # 优先使用项目级提示词
    $projectPrompt = Join-Path $ProjectRoot ".codex-polish\prompts\report-finalize.md"
    if (Test-Path $projectPrompt) {
        return $projectPrompt
    }
    
    # 回退到全局提示词
    $globalPrompt = Join-Path $env:CODEX_POLISH_HOME "prompts\polish\report-finalize.md"
    return $globalPrompt
}

# 草稿文件目录
function Get-DraftDir {
    param([string]$ProjectRoot)
    
    $draftDir = Join-Path $ProjectRoot ".codex-polish\drafts"
    if (-not (Test-Path $draftDir)) {
        New-Item -ItemType Directory -Path $draftDir -Force | Out-Null
    }
    return $draftDir
}
```

### 3.2 确保 `runtime/codex-polish.ps1` 支持多平台

检查脚本是否正确处理：
- 路径分隔符（Windows 用 `\`，Linux/macOS 用 `/`）
- 换行符（Windows 用 CRLF，Linux/macOS 用 LF）
- CLI 调用方式

### 3.3 确保 `runtime/codex-report-finalize.ps1` 正确

检查入口脚本是否：
- 正确读取草稿文件
- 正确传递上下文
- 正确调用 `codex-polish.ps1`
- 草稿文件存放在 `.codex-polish/drafts/` 目录下（不是根目录）

## 第四步：执行安装

根据操作系统选择安装方式：

### Windows

```powershell
.\install.ps1
```

或双击 `install.cmd`

### Linux / macOS

```bash
pwsh ./install.ps1
```

安装脚本会自动：
1. 写入环境变量 `CODEX_POLISH_HOME`（指向当前工具目录）
2. 写入环境变量 `CODEX_POLISH_CMD`（指向 `runtime/codex-report-finalize.ps1`）
3. 在全局 `AGENTS.md` 中插入托管片段（调用润色命令）

## 第五步：验证安装

安装完成后，验证以下内容：

1. **环境变量**：
   ```powershell
   # Windows
   $env:CODEX_POLISH_HOME
   $env:CODEX_POLISH_CMD
   
   # Linux/macOS
   echo $CODEX_POLISH_HOME
   echo $CODEX_POLISH_CMD
   ```

2. **全局 AGENTS.md**：
   - 检查文件是否存在：`~/.codex/AGENTS.md`（或 `%USERPROFILE%\.codex\AGENTS.md`）
   - 检查是否包含润色命令调用

3. **提示词文件**：
   - 确认 `prompts/polish/report-finalize.md` 存在且内容正确

## 第六步：测试润色功能

创建一个测试草稿文件：

```powershell
# 创建测试目录
$testDir = ".codex-polish\drafts"
New-Item -ItemType Directory -Path $testDir -Force

# 创建测试草稿
$testDraft = @"
## 修复了登录 bug

问题原因：
- auth_provider.dart 中的 token 验证逻辑有问题
- 当 token 过期时，没有正确触发刷新流程

解决方案：
- 修改了 validateToken() 方法
- 添加了 refreshToken() 的自动调用
- 更新了错误处理逻辑

测试结果：
- 单元测试通过
- 集成测试通过
- 手动测试确认登录流程正常
"@

$testDraft | Out-File -FilePath "$testDir\test-draft.md" -Encoding UTF8

# 调用润色脚本
& $env:CODEX_POLISH_CMD -DraftFile "$testDir\test-draft.md"
```

如果输出了润色后的结果（比如用"宝宝"称呼、有生活化比喻），说明配置成功！

## 第七步：向用户汇报

汇报时必须包含以下信息：

### 7.1 环境检测结果

```
✓ 操作系统：[Windows/Linux/macOS]
✓ 检测到的 CLI 工具：[kiro/claude/gemini/...]
✓ 选择的润色工具：[kiro]
✓ Codex 全局目录：[路径]
✓ 工具安装目录：[路径]
```

### 7.2 安装结果

```
✓ 环境变量已写入
  - CODEX_POLISH_HOME = [路径]
  - CODEX_POLISH_CMD = [路径]
✓ 全局 AGENTS.md 已更新
✓ 提示词模板已就绪
```

### 7.3 测试结果

```
✓ 润色功能测试通过
```

或者如果测试失败：

```
✗ 润色功能测试失败
  原因：[具体错误信息]
  建议：[解决方案]
```

### 7.4 使用说明

告诉用户：

**1. 如何修改提示词模板**

全局模板位置：
```
[工具目录]/prompts/polish/report-finalize.md
```

如果想为某个项目单独设置提示词，在项目根目录创建：
```
.codex-polish/prompts/report-finalize.md
```

脚本会优先使用项目级提示词，如果没有才用全局的。

**2. 单项目独立人设示例**

比如你在做一个严肃的医疗项目，不想用"宝宝"这种称呼，可以在项目根目录创建：

```
.codex-polish/prompts/report-finalize.md
```

内容改成：

```markdown
你是一个专业的技术助手，负责把 GPT 的技术报告转述给开发者。

转述时需要做到：
* 保持专业但不失礼貌，称呼用户为"您"
* 用清晰的技术语言解释问题，但避免过度术语化
* 保留原文的所有关键信息
* 遇到英文文件名时，补充说明其功能

<recent_conversation_history>
{{RECENT_CONVERSATION_HISTORY}}
</recent_conversation_history>

<codex_report>
{{CODEX_REPORT}}
</codex_report>
```

这样在这个项目里，Codex 就会用专业风格润色报告，而不是"大姐姐"风格。

**3. 如何卸载**

```powershell
.\install.ps1 -Uninstall
```

卸载会：
- 删除环境变量
- 从全局 AGENTS.md 移除托管片段
- 但不会删除工具目录本身

**4. 如果移动了工具目录**

需要重新运行一次安装：

```powershell
.\install.ps1
```

这样全局 AGENTS.md 中的命令路径会更新到新位置。

## 注意事项

1. **不要假设环境固定**：
   - 先检测再执行，不要硬编码路径
   - 如果缺少必要工具，明确告知用户并提供安装建议

2. **保持工具自包含**：
   - 所有提示词保留在 `prompts/` 下，不要复制到全局目录
   - 运行时脚本保留在 `runtime/` 下
   - 草稿文件放在项目的 `.codex-polish/drafts/` 下，不要直接放根目录

3. **错误处理**：
   - 如果安装失败，明确说明失败在哪一步
   - 提供回滚方案或手动修复建议

4. **跨平台兼容**：
   - PowerShell 脚本要兼容 Windows/Linux/macOS
   - 路径分隔符要正确处理（用 `Join-Path` 而不是硬编码 `\` 或 `/`）

## 开始执行

现在请按上述步骤开始配置。先完成环境检测，然后询问我的选择，再执行安装和测试。
```

---

## 给分享者的提醒

如果你的用户想要修改提示词风格，提醒他们：

1. **安装前修改**：直接编辑 `prompts/polish/report-finalize.md`
2. **安装后修改**：编辑工具目录下的 `prompts/polish/report-finalize.md`，修改会立即生效
3. **项目级覆盖**：在项目根目录创建 `.codex-polish/prompts/report-finalize.md`

---

## 常见问题

### Q: 用户的机器上没有 PowerShell 7 怎么办？

A: Codex 会检测到并提示用户安装：
- Windows: `winget install Microsoft.PowerShell`
- Linux: 参考 https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux
- macOS: `brew install powershell`

### Q: 用户不想用 Kiro，想用其他工具怎么办？

A: Codex 会在第二步询问用户偏好，用户可以选择任何检测到的工具。

### Q: 用户的项目需要不同的润色风格怎么办？

A: 在项目根目录创建 `.codex-polish/prompts/report-finalize.md`，脚本会优先使用项目级提示词。

### Q: 安装后 Codex 还是没有自动润色怎么办？

A: 检查：
1. 全局 AGENTS.md 是否包含托管片段
2. 环境变量是否正确设置
3. 重启 Codex CLI（让环境变量生效）
