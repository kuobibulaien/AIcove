<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->

# 开发环境

- macOS / zsh（2026-07 由 Windows 迁移而来；node 经 nvm 安装，用前 `. ~/.nvm/nvm.sh`）
- Flutter 项目，改完代码用 `flutter run --no-resident` 验证
- 版本控制：仓库根目录单一 git 仓库，本地为主；构建产物与密钥已由 .gitignore 挡住

# 工作流程

全程中文对话。总路线：**模糊需求 → 分级提问澄清 → prd.md → codex 审方案 → 实现 → codex 审代码 → 沉淀知识**。

1. **先查后动**：改代码前先找相关文档，不确定就调查清楚；代码和文档能回答的问题不许问用户
2. **分级提问**（详见 trellis-brainstorm 技能）：只问两类问题——本次目标与验收、难回头的全局架构决策（必须附推荐答案＋理由＋代价）；技术选型与实现方案由 AI 自主设计，写入 prd.md「自主决策」段供用户扫读否决；典型任务 1~3 问收敛
3. **先说再做**：编码前描述方案等批准；方案获批后、动工前，用 `/codex:review` 请 Codex 审查方案
4. **拆大为小**（两层规则）：改动超 3 个文件先在 Trellis 建任务（含 `implement.md` 清单）；只有当需求包含多个可独立验收的交付物时才拆父子任务，单一功能自然跨多文件不硬拆
5. **写完必跑**：按根 `README.md` 项目宪法第 7 条交付检查（`flutter pub get` → 编译运行 → 窄/宽屏各验一次）
6. **完工必审**：实现完成后用 `/codex:review` 请 Codex 审查代码，问题修完再收尾；review gate 保持关闭，审查手动触发
7. **收尾检查**：完成后列出潜在问题；发现 bug 先写复现测试再修

## 确认机制

- **重大变更须确认**：文件结构增删、核心算法、新依赖、API 定义——先提方案问"您同意吗？"，批准后再动
- **局部优化可自主**：函数内部重构、命名优化等不影响外部调用的可以直接做，报告里说明即可

## 遇到问题必须停

命令报错、测试不过、发现逻辑漏洞——需要报告，报告：遇到了什么、原计划是什么、建议怎么办。报告后直接继续修复，保证开发效率。

# 编码规范

如无必要，勿增实体（指不必要的复杂度和重复代码；可复用的公共组件应积极创建）。

遵循 KISS、YAGNI、DRY、SOLID。编码风格与代码库保持一致，优先复用已有函数。

# 项目背景

- 开工前必读：根目录 `README.md`（含项目宪法）
- 术语口径：`.trellis/spec/project/glossary.md`（词汇表）；重大决策：`.trellis/spec/project/decisions/`（ADR）
- 涉及前端界面时必读：`apps/aicove_flutter/docs/公共组件总览.md`
- 文档库总入口：`apps/aicove_flutter/docs/README.md`
- 云端文档：`cloud_backend/README.md`
- 遇到问题多查文档库，解决后也往文档库里记录

# Trellis 文档系统

项目已完整接入 Trellis（CLI ＋ 钩子自动注入），`.trellis/` 管理可渐进加载的项目知识：

- `.trellis/workflow.md`：任务生命周期与工作流
- `.trellis/spec/`：长期有效的项目规范、架构边界、词汇表与决策卡
- `.trellis/tasks/`：大任务的 PRD、研究记录、验收标准
- `.trellis/workspace/`：会话日志、交接与阶段性决策

使用规则：

1. 新任务开始前，优先读取 `.trellis/spec/README.md` 和相关领域 spec。
2. 大任务、跨 3 个以上文件的变更，先在 `.trellis/tasks/` 建任务文档，再实现。
3. 可复用经验、踩坑结论、架构决定写回 `.trellis/spec/`；临时过程写入 `.trellis/workspace/` 或 `scratch/`。
4. 完成实现、修 bug、架构讨论或检查后，必须判断是否产生长期有效知识；如果有，自动更新 `.trellis/spec/` 或 `apps/aicove_flutter/docs/`。
5. 只在接口、架构、组件、踩坑、约定变化时更新文档；小改动不要制造文档噪音。
6. `AGENTS.md` 只保留全局硬规则和入口说明，不再堆大量模块细节。

# 高风险操作（须确认）

以下操作执行前必须告知用户并获得确认：

| 类别 | 示例 |
|------|------|
| 文件系统 | 删除文件/目录、批量修改、覆盖系统文件 |
| 版本控制 | git commit / push / reset --hard |
| 系统配置 | 环境变量、全局配置、权限变更 |
| 数据操作 | 删数据、改表结构、批量更新 |
| 网络请求 | 含敏感数据的请求、调用生产环境 API |
| 包管理 | 全局安装/卸载、更新核心依赖 |

确认格式：
> ⚠️ 危险操作：[操作内容]，影响范围：[说明]，风险：[后果]。确认执行？

# MCP 服务

`fast-context` 语义搜索原配置在 Windows 机器上，迁移后尚未在本机重新配置——配置好之前不要调用。重配后在此更新调用示例。
