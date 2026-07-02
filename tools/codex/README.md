# Codex Polish Tool

一个便携的 Codex 报告润色工具包。

目标只有两个：

- 一键安装，尽量少折腾
- 脚本、提示词、安装入口都放在同一个文件夹里，方便你直接分享

如果你想让别人把“安装要求”直接发给 Codex，让 Codex 自己根据环境完成配置，看这个文件：

- `INSTALL_FOR_CODEX.md`

## 目录说明

```text
tools/codex/
├─ BOOTSTRAP_ADAPTIVE.md
├─ BOOTSTRAP_FULL.md
├─ install.cmd
├─ install.ps1
├─ INSTALL_FOR_CODEX.md
├─ README.md
├─ prompts/
│  ├─ codex/
│  │  └─ global-agents.md
│  └─ polish/
│     └─ report-finalize.md
└─ runtime/
   ├─ codex-polish-settings.ps1
   ├─ codex-polish.ps1
   └─ codex-report-finalize.ps1
```

### 给人看的

- `install.cmd`
- `install.ps1`
- `INSTALL_FOR_CODEX.md`
- `README.md`
- `prompts/`

### 给 AI / 脚本自己看的

- `runtime/`

`runtime/` 里的文件是内部实现，平时不用改。你真正会碰的，通常只有安装脚本和 `prompts/`。

## 每个文件是干什么的

### 顶层文件

- `install.cmd`
  Windows 双击入口。它本身不做安装逻辑，只负责找到 PowerShell，然后转调 `install.ps1`。

- `install.ps1`
  真正的安装/卸载脚本。负责识别 `CODEX_HOME`、写环境变量、按需更新全局 `AGENTS.md` 托管片段。

- `INSTALL_FOR_CODEX.md`
  给别人复制后发给 Codex 的安装说明模板。适合“让 Codex 根据当前机器环境自己完成配置”这种场景。

- `README.md`
  这份说明文档。告诉人怎么安装、怎么改提示词、目录里每个文件负责什么。

### prompts 目录

- `prompts/codex/global-agents.md`
  给 Codex 全局 `AGENTS.md` 注入的模板内容。安装时会把里面的 `{{FINALIZE_COMMAND}}` 替换成真实脚本路径。

- `prompts/polish/report-finalize.md`
  给润色工具本身用的提示词模板。决定最终回复的语气、结构和保留信息的规则。

### runtime 目录

- `runtime/codex-polish-settings.ps1`
  润色工具的配置层。负责 provider 默认值、模型默认值、提示词路径解析、工作目录解析等公共设置。

- `runtime/codex-polish.ps1`
  底层润色执行脚本。负责真正调用 Claude Code / Gemini / Kiro 等 provider，并把草稿和上下文拼成最终请求。

- `runtime/codex-report-finalize.ps1`
  最终报告润色入口。它会读取草稿、整理上下文、调用 `runtime/codex-polish.ps1`，并输出最终可发送内容。

## 一键安装

### Windows

直接双击：

```text
tools/codex/install.cmd
```

或者在 PowerShell 里运行：

```powershell
.\tools\codex\install.ps1
```

默认行为：

- 写入用户级环境变量 `CODEX_POLISH_HOME`
- 写入用户级环境变量 `CODEX_POLISH_CMD`
- 检测全局 `AGENTS.md`
- 如果找到 `.codex`，自动把托管片段写入全局 `AGENTS.md`

安装不会把提示词复制到全局目录。

提示词始终留在当前这个文件夹里：

- `tools/codex/prompts/codex/global-agents.md`
- `tools/codex/prompts/polish/report-finalize.md`

## 卸载

```powershell
.\tools\codex\install.ps1 -Uninstall
```

卸载会做这几件事：

- 删除 `CODEX_POLISH_HOME`
- 删除 `CODEX_POLISH_CMD`
- 从全局 `AGENTS.md` 移除这个工具写入的托管片段

卸载不会删除 `tools/codex/` 目录本身。

## 提示词怎么改

### 1. 改 Codex 的全局接入提示词

编辑：

```text
tools/codex/prompts/codex/global-agents.md
```

这个文件决定安装器往全局 `AGENTS.md` 里写什么内容。

适合改的内容：

- 最终回复前要不要强制走润色
- 子代理要不要豁免
- 润色失败时怎么回退

文件里有一个占位符：

```text
{{FINALIZE_COMMAND}}
```

安装时会自动替换成当前机器上的实际命令路径。

### 2. 改润色工具本身的提示词

编辑：

```text
tools/codex/prompts/polish/report-finalize.md
```

这个文件决定润色器怎么改写最终回复。

适合改的内容：

- 语气
- 结构
- 信息保留规则
- 禁止事项

当前默认链路是：

- provider: `kiro`
- model: `claude-sonnet-4.5`

虽然以前旧模板名叫 `gemini-translate-report.txt`，现在已经统一收敛到 `report-finalize.md` 了。

## 运行方式

安装完成后，Codex 会通过全局 `AGENTS.md` 中的托管片段，直接调用：

```text
tools/codex/runtime/codex-report-finalize.ps1
```

一般不需要你手动运行它。

如果只是想调试，也可以直接执行：

```powershell
.\tools\codex\runtime\codex-report-finalize.ps1 -DraftFile .\.codex-polish\drafts\draft.md
```

## 全局路径说明

安装时会优先识别：

- `CODEX_HOME`

如果没设置，则使用默认位置：

- Windows: `%USERPROFILE%\.codex`
- Linux/macOS: `~/.codex`

全局 `AGENTS.md` 路径是：

- Windows: `%USERPROFILE%\.codex\AGENTS.md`
- Linux/macOS: `~/.codex/AGENTS.md`

如果安装时没找到 `.codex` 目录，会跳过自动接入，并提示你手动处理 `AGENTS.md`。

## 分享给别人时怎么做

直接把整个 `tools/codex` 文件夹发给别人就行。

对方只需要：

1. 按需修改 `prompts/`
2. 双击 `install.cmd`

这样脚本、提示词、安装入口始终在一起，不会出现“脚本一份、提示词另一份”的问题。

## 注意

如果你把 `tools/codex` 整个文件夹挪位置了，需要重新执行一次安装。

原因很简单：全局 `AGENTS.md` 里记录的是这个工具当前所在位置的命令路径，移动目录后路径会变。

Linux / macOS 用户不要运行 `install.cmd`。

非 Windows 平台请使用：

```bash
pwsh ./tools/codex/install.ps1
```
