# 节点库真实运行态预览改造

## 目标

把 Agent Context Studio 的节点库从“只能编辑静态示例”改成可用于真实提示词调试的编辑台。

核心目标：

- 变量节点必须说明值从哪里来、运行时结构是什么、示例值只是 fallback。
- Prompt / Agent Build 预览必须能看到变量替换后的结果。
- 模板变量与变量库之间必须有校验提示，避免模板引用空气变量。
- `state_json` 这类运行态变量要展示完整结构，不再只给两项短样例。

## 范围

- `apps/aicove_flutter/assets/prompt_defaults.json`
- `apps/aicove_flutter/assets/agent_context_defaults.json`
- `cloud_backend/prompt_defaults_admin_panel.html`
- `cloud_backend/agent_context_admin_api.py`
- 相关 Flutter 运行时代码中实际注入变量的位置
- 相关后端 / Flutter 测试

## 验收

- 节点库变量详情能展示运行态来源和结构。
- `state_json` 示例覆盖真实运行时字段。
- Prompt 详情与 Agent Build 预览能提供示例渲染结果。
- 面板能提示未定义占位符、未使用声明变量、孤立变量。
- 默认变量库补齐当前模板实际使用的变量，或明确标注非 prompt 运行时变量用途。
- 测试覆盖后端变量校验/预览输出，以及 Flutter 默认资产加载的关键字段。
