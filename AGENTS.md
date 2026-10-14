# AIcove 协作规则

本文是所有 agent（Claude Code、Codex、Pi、Gemini 等）的唯一规则入口。AIcove 是本地运行、隐私优先的 AI 陪伴聊天客户端（Flutter）＋用户自部署的云同步服务（`cloud_backend/`）。不是治疗产品，不做心理监控或内容审核（ADR0066）；不支持 Web 端。

## 开工与收工

- **开工**：读 `docs/项目记忆/README.md`（当前状态，支持 hook 的平台自动注入）。写代码前读 `DEVELOPMENT.md`「项目宪法」；其余文档按下面的文档地图按需读，只读相关章节。
- **收工**（仅限有实际改动的任务）：
  1. 需求日志：把 hook 写入条目的 `结果：（待补）` 改成一句结果。hook 没写入的 harness 自己补完整条目。
  2. 状态变了：在项目记忆 README 对应行**原地改写**为当前状态，不追加过程。
  3. 架构级决定（选型、数据流／真相源、跨层边界）：新建 `docs/项目记忆/决策记录/NNNN-标题.md`，在索引加一行。被取代的旧 ADR 标 superseded 并注明替代者。
  4. 修了「表面原因≠真实原因」的 bug：在 `经验教训.md` 追加一条硬约束和正例路径。
- 回查历史对话原文：`trellis mem search <关键词>`。

## 工作方式

全程中文。默认由主会话独立完成；只有用户在当次请求中点名时，才使用外部模型或多代理。

1. **先查后动**：代码和文档能回答的问题不问用户。
2. **只问两类问题**：本次目标与验收，以及难回头的架构决策（附推荐答案、理由和代价）。实现方案自己定，写进方案里供用户否决。典型任务 1～3 问。
3. **按风险推进**：已授权范围内的本地改动直接做，跨多文件也不硬拆。触及架构边界、数据契约或下面「需确认」的事项时，先给目标、边界、验收、回滚和执行清单，确认后再动工。需求包含多个可独立验收的交付物时，分批交付。
4. **写完必验**：验证方式按 `DEVELOPMENT.md` 宪法第 7 条选。修 bug 先写复现测试。目标行为验证通过、diff 审过就收工，不顺手扩大范围，不罗列假设风险。
5. **界面改动附预览**：改了用户可见的 Flutter 界面，汇报里直接嵌入基于修改后源码的 Flutter 渲染预览图（热重载失败也要生成），并标明「源码渲染预览」，不能冒充实机截图。

## 授权边界

- **需确认**：删除文件或目录、数据／schema 迁移、核心依赖更新、公开 API 或核心算法变更、生产请求、系统权限与全局配置变更。
- **直接做**：范围内的本地编辑、格式化、测试、静态检查、可恢复的配置修改。报错或测试失败时，在范围内自行修复，不停下来问。
- **Git**：可自行提交，保护工作树里他人的改动，禁止 destructive reset。不部署，不碰生产环境或账户状态，除非用户明确要求。用户说「直接安装」时，装到设备即可，不做验证。
- **公开发布**：公开仓库是 GitHub `kuobibulaien/AIcove`。本地 main 含私人历史，**禁止直接 push**。发布只用 `python3 apps/aicove_flutter/tool/publish_release.py <版本>`，流程见 [DIAGNOSTICS.md「公开发布」](apps/aicove_flutter/tool/DIAGNOSTICS.md#公开发布)。`需求日志.md`、`opusdocs/`、本地抓取的第三方资料只存本地，不 `git add -f`；提交前用 `git ls-files -ci --exclude-standard` 确认没有被忽略却仍被跟踪的文件。

## 运行与调试

- **Flutter**：只用 `apps/aicove_flutter/tool/flutterw`，不用全局 `flutter`。node 用前先执行 `. ~/.nvm/nvm.sh`。命令、Dart MCP 与调试会话见 [DIAGNOSTICS.md](apps/aicove_flutter/tool/DIAGNOSTICS.md)。MCP 工具可见，不等于已连上应用；组件树可读，不等于外观通过。
- **手机运行问题**：先在 `apps/aicove_flutter/` 执行 `python3 tool/collect_diagnostics.py --release --since 2h --print` 抓当前日志，再定位代码。不把抓日志交给用户，不要求切 Debug 或开开关，排查结束后不关读取服务。先保全现场，再重启或重装。凭证不写进文档。
- **Mac 界面验收不抢前台**：优先用终端，或用 Computer Use 后台操作。不调用 `activateIgnoringOtherApps`／`AXRaise`／全局鼠标键盘事件。确实需要影响桌面时，先说明必要性和占用时间。验收标准不因此降低。
- **真实模型测试**：默认用 DeepSeek `deepseek-flash`（`https://api.deepseek.com`，OpenAI 格式）。Key 在本机 `~/.zshenv` 导出为 `DEEPSEEK_API_KEY`，新开的 shell 都能直接读到，不要再找用户要。Key 本身不写进仓库。

## 编码

KISS、YAGNI、DRY，风格跟随现有代码，优先复用。可复用的公共组件要积极抽出来，但不加不必要的复杂度。

## 文档地图

每条规则只放在一个地方，别处只放链接。

| 内容 | 唯一位置 |
|---|---|
| 执行方式、授权、文档地图 | 本文 |
| 架构约束、项目宪法、验证流程 | `DEVELOPMENT.md` |
| 命令：日志、调试、MCP、SDK、发布 | `apps/aicove_flutter/tool/DIAGNOSTICS.md` |
| 当前状态（每次注入） | `docs/项目记忆/README.md` |
| 架构决策 / 踩坑硬约束 / 术语 | `docs/项目记忆/决策记录/`、`经验教训.md`、`术语表.md` |
| 界面布局规范 / 公共组件 | `apps/aicove_flutter/docs/界面布局说明.md`、`公共组件总览.md`（只查用到的章节） |
| 模块说明 | `apps/aicove_flutter/docs/`（入口 `README.md`） |
| 产品介绍（给用户看） | 根 `README.md` |
| 草稿、排查输出 | `scratch/`，不作为规范 |

**不写文档的情况**：一次性排查过程、纯样式／格式调整、看代码和测试就能推出的事实，以及已经记在别处的内容。完成使命的方案移入 `apps/aicove_flutter/docs/05_历史归档/<日期>_<主题>/`。改公共组件时，同步更新 `公共组件总览.md`。
