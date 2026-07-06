# Glossary Format（.trellis/spec/project/glossary.md）

## Structure

```md
# AIcove 项目词汇表

一两句话说明这个词汇表的作用与适用范围。

## Language

**订单（Order）**：
客户提交的一次购买请求。
_避免使用_：交易、purchase

**发票（Invoice）**：
交付后向客户发出的付款请求。
_避免使用_：账单、bill
```

## Rules

- **Be opinionated.** When multiple words exist for the same concept, pick the best one and list the others under `_避免使用_`.
- **Keep definitions tight.** One or two sentences max. Define what it IS, not what it does.
- **Only include terms specific to this project's context.** General programming concepts (timeouts, error types, utility patterns) don't belong even if the project uses them extensively. Before adding a term, ask: is this a concept unique to this project's domain, or a general programming concept? Only the former belongs.
- **Group terms under subheadings** when natural clusters emerge (e.g. 前端 / 云端 / Agent 运行时). If all terms belong to a single cohesive area, a flat list is fine.
- 中文为主，首次出现附英文原名；代码标识符保持原文。

## 多领域扩展

主词汇表是 `.trellis/spec/project/glossary.md`。只有当某个领域（frontend / backend / agent-context）的词汇多到挤占主表时，才在 `.trellis/spec/<domain>/glossary.md` 分家，并在主表开头列出链接与一句话分工。不要预先建立空的分表。
