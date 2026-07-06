---
name: domain-modeling
description: Build and sharpen the project's domain model. Use when the user wants to pin down domain terminology or a ubiquitous language, record an architectural decision, or when another skill (e.g. trellis-brainstorm) needs to maintain the domain model during requirements discovery.
---

# Domain Modeling

Actively build and sharpen the project's domain model as you design. This is the *active* discipline — challenging terms, inventing edge-case scenarios, and writing the glossary and decisions down the moment they crystallise. (Merely *reading* the glossary for vocabulary is not this skill — that's a one-line habit any skill can do. This skill is for when you're changing the model, not just consuming it.)

> 本项目定制：词汇表与决策卡统一安家在 Trellis 知识库（`.trellis/spec/`），不使用根目录 CONTEXT.md 或 docs/adr/。长期知识只有一个家。

## File structure

```
.trellis/spec/project/
├── glossary.md          ← 项目词汇表（格式见 CONTEXT-FORMAT.md）
└── decisions/           ← ADR 决策卡（格式见 ADR-FORMAT.md）
    ├── 0001-example.md
    └── 0002-example.md
```

Create files lazily — only when you have something to write. If no `glossary.md` exists, create it when the first term is resolved, and add it to the reading-order table in `.trellis/spec/README.md`. If no `decisions/` exists, create it when the first ADR is needed.

If a single domain (frontend / backend / agent-context) accumulates enough vocabulary to crowd the main glossary, it may get its own `.trellis/spec/<domain>/glossary.md` — but only then, and `project/glossary.md` must link to it.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `glossary.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update the glossary inline

When a term is resolved, update `.trellis/spec/project/glossary.md` right there. Don't batch these up — capture them as they happen. Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

The glossary should be totally devoid of implementation details. Do not treat it as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.

### Offer ADRs sparingly

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. Use the format in [ADR-FORMAT.md](./ADR-FORMAT.md).

遵守本项目的分级提问契约：术语对质与场景推演不等于追问细枝末节——只在真出现口径冲突或边界模糊时开口，不为完备而提问。
