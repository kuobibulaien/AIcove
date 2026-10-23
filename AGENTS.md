# AIcove 协作说明

所有 agent（Claude Code、Codex、Pi 等）的共用入口，回复全程中文。AIcove 是本地运行、隐私优先的 AI 陪伴聊天客户端（Flutter）＋用户自部署的云同步服务（`cloud_backend/`）；不是治疗产品，不做心理监控或内容审核（ADR0066）；不支持 Web 端。

## 资料在哪

| 内容 | 位置 |
|---|---|
| 当前状态（hook 每次注入） | `docs/项目记忆/README.md` |
| 架构约束、项目宪法、验证方式 | `DEVELOPMENT.md` |
| 命令：日志、调试、Dart MCP、SDK、发布 | `apps/aicove_flutter/tool/DIAGNOSTICS.md` |
| 架构决策／模块边界／踩坑／术语 | `docs/项目记忆/决策记录/`、`模块边界补充.md`、`经验教训.md`、`术语表.md` |
| 用户原话与每次结果（仅本地） | `docs/项目记忆/需求日志.md`，续接上次任务时读末尾几条 |
| 界面布局、公共组件 | `apps/aicove_flutter/docs/界面布局说明.md`、`公共组件总览.md`（只查用到的章节） |
| 模块说明、已完成方案的归档 | `apps/aicove_flutter/docs/`（入口 `README.md`）、`05_历史归档/` |
| 历史对话原文 | `trellis mem search <关键词>` |
| 草稿、排查输出 | `scratch/` |

## 用户习惯

- 能从代码和文档查到的不问；只问本次目标与验收，以及难回头的架构决策（附推荐）。实现方案自己定。
- 范围内的本地改动、测试、修错直接做；删除文件、数据／schema 迁移、核心依赖、公开 API、全局配置、生产环境，先说明再动。
- 写完要验证，方式见 `DEVELOPMENT.md` 宪法第 7 条（默认 Mac 窄屏，不占用户手机）；修 bug 先写复现测试；不顺手扩大范围。
- 改了用户可见界面，汇报附基于修改后源码的 Flutter 渲染预览图，标明「源码渲染预览」。
- 默认主会话独立完成，外部模型和子代理只在用户点名时用。
- 有实际改动时收工：补需求日志本次条目的「结果」一句；状态变了就原地改写 README 那一行；架构级决定写 ADR 并加索引；「表面原因≠真实原因」的 bug 记进经验教训。hook 实现在 `hooks/memory.py`。
- 编码：KISS、YAGNI、DRY，跟随现有风格；改公共组件同步 `公共组件总览.md`。

## 环境

- Flutter 只用 `apps/aicove_flutter/tool/flutterw`；node 用前 `. ~/.nvm/nvm.sh`。Dart MCP 工具可见不等于已连上应用。
- 手机问题先在 `apps/aicove_flutter/` 跑 `python3 tool/collect_diagnostics.py --release --since 2h --print` 抓日志，先保全现场再重启或重装。装手机用 `adb -s <id> install -r <apk>`，`flutter install` 会先卸载清数据。用户说「直接安装」时装上即可。
- Mac 界面验收不抢前台：不调 `activateIgnoringOtherApps`／`AXRaise`／全局鼠标键盘事件；Computer Use 须用户当次授权，否则启动调试会话后列测试步骤给用户。
- 真实模型测试：DeepSeek `deepseek-flash`（`https://api.deepseek.com`，OpenAI 格式），Key 是 `~/.zshenv` 里的 `DEEPSEEK_API_KEY`，不写进仓库。
- 部分文件是 CRLF，脚本改写时保留原换行（Python 用 `newline=''`），改完看 `git diff --stat`。

## Git 与公开发布

- 默认直接在主目录的 main 上改和提交，不新开分支或 worktree；只有项目大改（跨多个模块的重构、架构调整、数据迁移）才开分支，并先说明。修 bug、小功能、打包都不开。
- 可自行提交；不做 destructive reset；保护工作树里他人的改动；不部署、不碰生产环境。
- 本地 main 含私人历史，禁止直接 push。公开仓库 `kuobibulaien/AIcove`，发布只用 `python3 apps/aicove_flutter/tool/publish_release.py <版本>`（见 DIAGNOSTICS.md「公开发布」）。
- `需求日志.md`、`opusdocs/`、第三方预设与抓取资料只存本地（第三方预设公开即侵权），不 `git add -f`；提交前跑 `git ls-files -ci --exclude-standard`。
