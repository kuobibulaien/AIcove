# ADR Format（.trellis/spec/project/decisions/）

ADRs live in `.trellis/spec/project/decisions/` and use sequential numbering: `0001-slug.md`, `0002-slug.md`, etc.

Create the `decisions/` directory lazily — only when the first ADR is needed.

## Template

```md
# {决策的短标题}

{1-3 句话：背景是什么、决定了什么、为什么。}
```

That's it. An ADR can be a single paragraph. The value is in recording *that* a decision was made and *why* — not in filling out sections.

## Optional sections

Only include these when they add genuine value. Most ADRs won't need them.

- **Status** frontmatter (`proposed | accepted | deprecated | superseded by ADR-NNNN`) — useful when decisions are revisited
- **Considered Options** — only when the rejected alternatives are worth remembering
- **Consequences** — only when non-obvious downstream effects need to be called out

## Numbering

Scan `decisions/` for the highest existing number and increment by one.

## When to offer an ADR

All three of these must be true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will look at the code and wonder "why on earth did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If a decision is easy to reverse, skip it — you'll just reverse it. If it's not surprising, nobody will wonder why. If there was no real alternative, there's nothing to record beyond "we did the obvious thing."

### What qualifies

- **Architectural shape.** "前后端通过 REST 分离"、"Agent 运行时事件溯源"
- **Integration patterns between contexts.** 模块间靠什么通信、边界在哪
- **Technology choices that carry lock-in.** Database, message bus, auth provider, deployment target. Not every library — just the ones that would take a quarter to swap out.
- **Boundary and scope decisions.** 数据归谁所有、其他模块只能引用 ID——明确的"不做"和"做"一样有价值
- **Deliberate deviations from the obvious path.** Anything where a reasonable reader would assume the opposite. These stop the next engineer from "fixing" something that was deliberate.
- **Constraints not visible in the code.** 合规要求、性能红线、外部契约
- **Rejected alternatives when the rejection is non-obvious.** 认真考虑过又放弃的方案要记下来——否则六个月后一定有人再提一遍
