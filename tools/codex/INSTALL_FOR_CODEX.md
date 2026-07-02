# 给 Codex 的安装说明

这份文件是给人复制后发给 Codex 用的。

如果你想让 Codex 根据当前机器的实际情况，自动完成这套润色工具的安装或卸载，直接把下面的提示词整段发给它即可。

使用前只需要做一件事：

- 把文中的 `<TOOL_ROOT>` 替换成这套工具所在目录的绝对路径

例如当前仓库里，这个路径就是：

```text
C:\ide\aicove\tools\codex
```

## 发给 Codex 的提示词

```text
你现在要为当前机器配置一套 Codex 润色工具。

工具根目录是：<TOOL_ROOT>

请不要先假设环境固定，先根据当前机器的真实情况检查后再执行。

目标：
1. 保持工具目录自包含。
2. 所有提示词保留在 <TOOL_ROOT>\prompts 下，不要复制到全局目录。
3. 运行时脚本保留在 <TOOL_ROOT>\runtime 下。
4. <TOOL_ROOT> 根目录只保留安装入口、说明文档和 prompts，不要再额外生成同名执行脚本壳。
5. 安装时只做两类事情：
   - 写环境变量
   - 按需写入全局 AGENTS.md 的托管片段
6. 如果找不到 .codex 目录，不要强行创建完整全局环境；应跳过 AGENTS 自动接入，并明确告诉用户需要手动处理。

你必须按下面顺序工作：

第一步：检查环境
- 确认 <TOOL_ROOT> 是否存在。
- 确认 <TOOL_ROOT>\install.ps1 是否存在。
- 识别当前系统是 Windows、Linux 还是 macOS。
- 检查是否可用 PowerShell 7（pwsh）。
- 检查是否设置了 CODEX_HOME。
- 如果没有设置 CODEX_HOME：
  - Windows 默认使用 %USERPROFILE%\.codex
  - Linux / macOS 默认使用 ~/.codex

第二步：决定安装方式
- 如果是 Windows：
  - 可以使用 <TOOL_ROOT>\install.cmd
  - 或直接运行 <TOOL_ROOT>\install.ps1
- 如果是 Linux / macOS：
  - 不要使用 install.cmd
  - 只使用 pwsh 执行 <TOOL_ROOT>/install.ps1
- 如果用户明确说“不要改全局 AGENTS.md”，安装时加上 -SkipAgents。
- 如果用户明确要卸载，则执行 install.ps1 -Uninstall，而不是安装。

第三步：执行时必须遵守这些规则
- 不要把 prompts 目录复制到全局目录。
- 不要把 runtime 目录复制到全局目录。
- 不要创建第二套脚本副本。
- 全局 AGENTS.md 中写入的命令必须直接指向 <TOOL_ROOT>\runtime\codex-report-finalize.ps1。
- 不要修改 prompts 的内容，除非用户明确要求。
- 不要编造“已安装成功”；要用真实检查结果确认。

第四步：安装完成后必须验证
- 检查环境变量：
  - CODEX_POLISH_HOME
  - CODEX_POLISH_CMD
- 如果执行了 AGENTS 自动接入：
  - 检查全局 AGENTS.md 是否存在托管片段
  - 确认托管片段中的命令路径指向当前 <TOOL_ROOT>
- 确认 prompts 仍然在 <TOOL_ROOT>\prompts 下，没有被复制走

第五步：向用户汇报时必须说清楚
- 实际识别到的系统类型
- 实际使用的安装命令
- 实际识别到的 CODEX_HOME
- 是否写入了 AGENTS.md
- 如果有跳过项，为什么跳过
- 如果失败，失败在哪一步

额外要求：
- 如果当前环境不满足条件，例如 Linux / macOS 上没有 pwsh，不要硬装；要停下来并明确告诉用户缺什么。
- 如果 .codex 不存在，只安装工具相关环境变量即可，并提示用户自行配置 AGENTS.md。
- 如果工具目录以后被移动，提醒用户重新执行一次安装，让 AGENTS.md 中的路径更新。
```

## 备注

如果你只想让 Codex 帮你“安装但不要改全局 AGENTS.md”，可以在把上面提示词发给它之前，额外补一句：

```text
只安装工具，不要自动修改全局 AGENTS.md。
```

如果你想让 Codex 帮你“卸载”，可以额外补一句：

```text
不要安装，请按当前环境执行卸载。
```
