# 角色卡背景展开动效（无缝展开 A + 三组件飞行）施工文档

面向：施工 AI / 开发同学  
目标（用户明确要求）：不要遮罩、不要淡入淡出、不要阴影等“花里胡哨”。只要：
- 点击后“静态模糊背景图”做 **无缝展开（原地撑开）**
- 三个组件做 **飞行 + 形变**（建议：海报图 / 名字 / 简介框）
- 不使用实时全屏高斯模糊
- 第一次点开不空白、不突变（通过预热 + 低清兜底实现）
- 动画过程可返回打断

---

## 1. 背景与现状（为什么你现在只看到“淡入淡出”）

当前实现里有两处“实时模糊”：

- 卡片毛玻璃背景：`FrostedGlassCard` 使用 `BackdropFilter(ImageFilter.blur)`  
  文件：`apps/mygril_flutter/lib/src/core/widgets/frosted_glass_card.dart`
- 详情页全屏背景：`CharacterDetailPage` 使用 `ImageFiltered(ImageFilter.blur(sigma 60))`  
  文件：`apps/mygril_flutter/lib/src/features/chat/presentation/pages/character_detail_page.dart`

实时模糊在卡片面积小的时候还好，但铺满全屏时会明显增加渲染压力；同时“路由先盖一层背景 + 内容延迟出现”会带来闪白/突变观感。

你现在只看到淡入淡出，常见原因（需要全部修正）：
- 入口用了整页 `FadeTransition`（把“展开”主角抢走了）
- 详情页加了大面积遮罩/渐变（把背景展开盖住了）
- `ExpandingPageRoute` 默认用 `contentOpacity` 做内容渐隐渐现（你明确不要）

本方案最终采用：
1) 用公共路由 `ExpandingPageRoute` 做“从卡片 Rect 撑开到全屏”的 **无缝展开（A）**
2) 用 `Hero` 做三组件飞行（海报图/名字/简介框）
3) 背景用“静态模糊图”（缓存/预热），禁用实时全屏模糊与遮罩/淡入

---

## 2. 动效定义（最终你要看到的效果）

像“画布变大 + 三个演员飞过去”理解：

1) 无缝展开（主动画）
- 起点：卡片在屏幕上的 `sourceRect`
- 终点：全屏 `Rect(0,0,w,h)`
- 内容：最底层就是“静态模糊背景图”，随着容器变大铺满

2) 三组件飞行 + 形变（只动这三个）
- 海报图：卡片左侧海报 → 详情页中间海报（`Hero(role_image_{id})`）
- 名字：卡片名字 → 顶部圆按钮行中间标题位（`Hero(role_name_{id})`）
- 简介框：卡片简介气泡 → 详情页更大的简介框（`Hero(role_intro_{id})`）

禁用项（必须遵守）：
- 禁止遮罩层（黑色遮罩、渐变遮罩都不要）
- 禁止淡入淡出（整页 Fade、内容 Opacity 渐变都不要）
- 禁止阴影（卡片/海报/信息卡的 boxShadow 全部去掉）
- 禁止实时全屏高斯模糊（`ImageFiltered.blur`/`BackdropFilter` 作为背景）

---

## 3. 复用的公共类（现成零件）

1) 毛玻璃卡片/容器（现成外观）
- `FrostedGlassCard` / `FrostedGlassContainer`  
  文件：`apps/mygril_flutter/lib/src/core/widgets/frosted_glass_card.dart`

2) 平滑圆角裁剪/装饰（圆角一致、飞行不露角）
- `SmoothClipRRect` / `SmoothRectDecoration`  
  文件：`apps/mygril_flutter/lib/src/core/widgets/smooth_clip.dart`

3) 路由动画参考（本方案不强依赖）
- 本方案核心：`ExpandingPageRoute`（无缝展开）  
  文件：`apps/mygril_flutter/lib/src/core/widgets/expanding_page_route.dart`

4) 现有主题色 token
- `MoeColors / tokens.dart`（保持配色一致）  
  文件：`apps/mygril_flutter/lib/src/core/theme/tokens.dart`

---

## 4. 需要新建的公共类（新增零件）

### 4.1 `RoleTransitionTags`（统一 Hero tag）

新建文件：`apps/mygril_flutter/lib/src/core/utils/role_transition_tags.dart`

职责：
- 统一管理 tag 字符串，避免散落在多个页面里手写导致冲突/拼错。

建议接口：
- `static String bg(String id) => 'role_bg_$id';`
- `static String image(String id) => 'role_image_$id';`（与现有保持一致）
- `static String name(String id) => 'role_name_$id';`
- （可选）`static String intro(String id) => 'role_intro_$id';`

### 4.2 `BlurredBackgroundCache`（静态模糊生成 + LRU 缓存 + 首次兜底）

新建文件：`apps/mygril_flutter/lib/src/core/utils/blurred_background_cache.dart`

职责：
- 输入：`conversationId + ImageProvider(海报图)`  
- 输出：用于渲染背景的 `ImageProvider` 或 `Widget`（优先静态模糊图，缺失时 fallback）。
- 支持：
  - `warm(...)`：列表首屏预热（尽量让“第一次点开”已生成）
  - `getOrFallback(...)`：点击时必须立刻能拿到背景（保证不空白）
  - 生成过程 in-flight 去重（同一 id 同时只生成一次）
  - LRU 容量限制（建议 12，避免内存无限增长）

**关键：首次不空白/不突变策略**
- 绝对禁止“点开等待模糊生成再 push”（会变慢/假卡）
- 绝对禁止“用淡入淡出偷偷糊弄过去”（用户明确不要淡入）
- 正确做法：只靠 **预热** + **低清兜底**，不做任何过渡叠加
  1) 列表首屏提前 warm：确保大部分情况下点击即命中静态模糊
  2) 如果没命中：fallback 返回 `ResizeImage(imageProvider, width: 32~64)` 的低清图放大（天然发糊，但不是滤镜）
  3) 本次进入详情页不做替换（避免突变/淡入），下次再进入命中静态模糊即可

### 4.3 `RoleBackgroundHero`（弃用：本需求不走背景 Hero）

状态：不推荐/应移除  
原因：背景如果用 `Hero`，本质是“贴纸变大”，不是你要的“无缝展开（Rect 撑开）”；而且你们现在实现里还带 `AnimatedSwitcher`/延时替换，属于淡入淡出范畴，和需求冲突。

处理建议：
- 不再创建/不再使用 `RoleBackgroundHero`
- 背景统一交给 `ExpandingPageRoute` 的“正在展开的容器”去展示（详情页本身的 Stack 底层放背景图即可）

职责：
- 把“背景贴纸 Hero”封装为一个可复用 widget。
- 参数建议：
  - `conversationId`
  - `imageProvider`（海报图，同源）
  - `borderRadius`（卡片端 16；详情页端 0）
  - `fit`（cover）
- 内部实现：
  - `Hero(tag: RoleTransitionTags.bg(id), flightShuttleBuilder: 圆角插值裁剪)`
  - 裁剪使用 `SmoothClipRRect`，圆角随飞行进度从 `fromRadius -> toRadius` 线性插值
  - child 使用 `BlurredBackgroundCache` 提供的背景（blurred 或 fallback）

---

## 5. 需要修改的业务文件（施工点）

### 5.1 角色卡页（起点）

文件：`apps/mygril_flutter/lib/src/features/chat/presentation/pages/role_card_page.dart`

施工目标（必须全部做到）：

1) 入口必须使用无缝展开路由（ExpandingPageRoute）
- 禁止：`PageRouteBuilder + FadeTransition`
- 正确：计算卡片 `sourceRect`，`Navigator.push(ExpandingPageRoute(page: CharacterDetailPage(...), sourceRect: sourceRect, ...))`

2) 卡片背景必须展示“静态模糊图”（或低清兜底），且不使用 BackdropFilter
- 禁止：卡片内 `BackdropFilter(ImageFilter.blur...)`
- 正确：卡片背景层直接 `DecorationImage(image: BlurredBackgroundCache.getOrFallback(...))` + `SmoothClipRRect(radius: 16)`

3) 三组件的起点（Hero 起点）必须在卡片里都存在
- 卡片名字 Text 外包：`Hero(tag: RoleTransitionTags.name(id), child: Text(...))`
- 卡片海报图外包：`Hero(tag: RoleTransitionTags.image(id), child: 海报图Widget)`
- 卡片简介框外包：`Hero(tag: RoleTransitionTags.intro(id), child: 简介框Widget)`

4) 预热（解决“第一次点开”）
- 列表首屏的每张卡片 build 后触发一次 `BlurredBackgroundCache.warm(id, imageProvider, context)`
- 并发限制 1–2（避免列表滑动卡顿）

5) 删除所有阴影与着色层
- 禁止：卡片外层 boxShadow、海报容器 boxShadow、任何“提亮/压暗”的 tint 层

### 5.2 详情页（终点）

文件：`apps/mygril_flutter/lib/src/features/chat/presentation/pages/character_detail_page.dart`

施工目标（必须全部做到）：

1) 背景：固定使用静态模糊图（或低清兜底），禁止实时全屏模糊
- 禁止：`ImageFiltered.blur`、`BackdropFilter` 作为全屏背景
- 正确：`Positioned.fill(child: 背景图Widget)`，背景图来源 `BlurredBackgroundCache.getOrFallback(...)`

2) 不压暗：删除遮罩/渐变层
- 禁止：任何覆盖全屏的遮罩、渐变、黑色层
- 可读性只靠“信息卡本身背景色/边框”

3) 布局必须改：三组件的落点要对应你要的“从哪里到哪里”
- 顶部圆按钮行：左返回按钮 + 中间 `Hero(role_name)` + 右编辑按钮
- 中间区域：`Hero(role_image)` 的海报图
- 下方区域：更大一点的 `Hero(role_intro)` 简介框（形变/放大/下沉）

注意：同一个 tag 在同一页面里只能出现一次，必须移除旧位置的同 tag Hero（否则 Hero 会失效，你只能看到淡入/跳变）。

4) 禁止任何“补救淡入”
- 不做落地后淡入替换、不做 AnimatedSwitcher
- 第一次如果只能拿到低清兜底，就保持低清兜底到本次结束；下次进入再命中静态模糊图

---

## 6. `FrostedGlassCard` 的处理（二选一）

你要“背景展开”走 Hero，且“不实时全屏模糊”，因此必须避免把 `BackdropFilter` 扩大到全屏。

推荐做法（改动最小、最稳）：

- 给 `FrostedGlassCard` 增加开关：`enableBackdropBlur`（默认 true）
  - 本动效场景：`enableBackdropBlur=false`（禁止 BackdropFilter）
- 再加开关：`enableTintLayer` / `tintOpacity`（默认保持旧逻辑）
  - 本动效场景：关闭 tint（你明确不要压暗/提亮）
- 阴影：本动效场景传入空 `boxShadow` 或提供 `enableShadow=false` 开关

对应文件：`apps/mygril_flutter/lib/src/core/widgets/frosted_glass_card.dart`

同时把“压暗/提亮层”也做成可配置（你明确不要压暗）。

---

## 7. 连续打断与防连点策略

1) 返回打断
- 天然支持：路由 reverse，Hero 回飞
- 施工重点：异步生成完成后不要对已销毁页面 setState（mounted 判断）

2) 连续点击不同卡片
- 加“防连点锁”：push 触发后到下一帧（或到 route 完成）忽略后续点击
- 避免多个路由叠加导致 Hero tag 冲突/跳帧

---

## 8. 验收清单（施工 AI 自测）

1) 第一次点开从未进入过的角色
- 背景立即出现（低清兜底也行），无空白/无闪白
- 背景随 `ExpandingPageRoute` 从卡片 Rect 撑开到全屏（这是主动画）
- 三组件飞行：海报图/名字/简介框都必须飞行与形变
- 不允许出现遮罩、淡入、阴影

2) 第二次点开同一角色
- 直接命中 cached blurred，过渡更丝滑

3) 性能
- 详情页背景不再出现 `ImageFiltered.blur`/`BackdropFilter` 的全屏滤镜

4) 打断
- 动画过程中返回，不卡死、不报错、Hero 正常回到卡片

---

## 9. 施工顺序建议（按这个做最省返工）

1) 新建/完善 `RoleTransitionTags`（补 `intro` tag）
2) 新建/完善 `BlurredBackgroundCache`
   - fallback 改为 `ResizeImage` 低清放大（不要直接返回原图）
   - warm 并发限制
3) 改 `ExpandingPageRoute`（这是“无缝展开”的发动机）
   - 删除遮罩层、删除整屏背景 fill 淡入
   - 删除内容 opacity 渐变（child 必须全程可见）
4) 改 `role_card_page.dart`
   - 路由改为 `ExpandingPageRoute`（禁止 PageRouteBuilder Fade）
   - 三个起点 Hero 都包好（海报/名字/简介）
   - 卡片背景不使用 BackdropFilter（用静态模糊或低清兜底）
   - 去掉所有阴影/着色层
5) 改 `character_detail_page.dart`
   - 背景改为静态模糊或低清兜底（不压暗、无遮罩）
   - 顶部名字落点到按钮行中间（移除信息卡里的 name Hero）
   - 增加简介框落点（Hero intro）
   - 去掉所有阴影
6) 改 `frosted_glass_card.dart`（为了全局可复用）
   - 增加 `enableBackdropBlur` / `enableTintLayer` / `enableShadow` 等开关

