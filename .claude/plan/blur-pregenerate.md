# 实施计划：角色背景模糊图预生成

## 任务类型
- [x] 前端
- [x] 后端
- [x] 全栈

## 问题描述
角色详情页打开时，背景先显示低像素清晰图（96x96 放大），等转场动画结束后才异步生成模糊图替换。用户设计意图是保存/导入时就预生成模糊图，打开直接用。

## 根因
1. 详情页用 `BlurredBackgroundCache`（内存级），运行时生成，且故意延后到转场结束
2. 卡片页用 `BlurredBackgroundManager`（文件级），两套系统互不复用
3. 保存/导入/同步流程中均无预生成模糊图的步骤
4. cache miss 时 fallback 是 96x96 原图放大，视觉上"闪清晰图"

## 技术方案

### 核心思路
合并两套模糊缓存为统一服务，在角色保存/导入/同步时预生成模糊图持久化到文件，详情页和卡片页统一消费。

### 关键决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 预生成挂点 | 持久化边界（保存/导入/同步） | 覆盖所有写入路径，不漏 |
| 缓存架构 | 文件层 + 内存 LRU 统一服务 | 合并两套系统，DRY |
| 文件格式 | JPEG 65% quality | 模糊图无高频细节，JPEG 比 PNG 小 80%，无可见差异 |
| 分辨率 | 短边 480px | 40-sigma 模糊下 720px 过度，480px 足够 |
| Fallback | 渐变/纯色 + 300ms fade-in | 不再用低清原图，避免"闪清晰图" |
| 旧数据迁移 | 混合：后台低优 + 首访懒生成 | 平衡体验和资源 |
| 目录 | 沿用 `blurred_backgrounds/` | 最小风险 |

## 实施步骤

### Step 1: 统一模糊服务
**合并 `BlurredBackgroundManager` + `BlurredBackgroundCache` 为单一服务**

- 新建或重构为 `BlurredBackgroundService`
- 文件层：持久化 blur JPEG 到 `blurred_backgrounds/`
- 内存层：LRU 缓存热点 `ImageProvider`，保留 in-flight 去重
- 文件命名：`v1_{sourceFingerprint}.jpg`（sourceFingerprint = 源路径/URL 的 md5）
- 统一 API：
  - `ensureBlur(String characterImage)` — 生成并持久化（保存/导入时调用）
  - `getBlurProvider(String characterImage)` — 获取 ImageProvider（UI 消费）
  - `evict(String characterImage)` — 清除旧 blur（角色图变更时）
- 生成参数：短边 480px，sigma 40，JPEG quality 65%
- 预期产物：统一的 blur 服务文件

### Step 2: 保存/创建时预生成
**在 `applyContactEdit()` 后触发 `ensureBlur()`**

- 文件：`conversation_providers.dart` (L130 附近)
- 在保存成功后异步调用 `BlurredBackgroundService.ensureBlur(characterImage)`
- 处理"清空角色图"情况：调用 `evict()` 清除旧 blur
- 网络图片：短超时尝试（3s），失败不阻塞保存，标记 pending
- 预期产物：保存后自动生成 blur 文件

### Step 3: 导入时预生成
**在导入落库后触发 `ensureBlur()`**

- 文件：`conversation_importer.dart` (L505 附近)
- 导入 `upsert()` 后异步调用 `ensureBlur(characterImage)`
- 仅处理本地/base64/asset 图片，网络图跳过（后续懒生成）
- 预期产物：导入后自动生成 blur 文件

### Step 4: 同步时预生成
**在远程同步写入后触发 `ensureBlur()`**

- 文件：`sync_service.dart` (L163 附近)
- 同步写入 `characterImage` 后异步调用 `ensureBlur()`
- 同 Step 3，网络图跳过
- 预期产物：同步后自动生成 blur 文件

### Step 5: 详情页消费统一服务
**改造 `character_detail_page.dart` 背景图逻辑**

- 去掉 `_scheduleBlurWarmupAfterTransition()` 延迟逻辑
- 去掉 `BlurredBackgroundCache.getOrFallback()` 调用
- 改为调用 `BlurredBackgroundService.getBlurProvider(characterImage)`
- 如果有预存文件 → 直接显示（Frame 1 可见）
- 如果没有（旧数据/网络图未就绪）→ 渐变色 fallback + 300ms fade-in
- 保留对 `*_blur` asset 的优先检查（兼容 nahida_blur.jpg）
- 预期产物：详情页零延迟显示模糊背景

### Step 6: 卡片页消费统一服务
**改造 `horizontal_role_card.dart` 背景图逻辑**

- 去掉对 `BlurredBackgroundManager` 的直接调用
- 改为调用 `BlurredBackgroundService.getBlurProvider(characterImage)`
- 统一 sigma、分辨率、裁切方式
- 预期产物：卡片页和详情页视觉一致

### Step 7: Fallback 改造
**将低清原图 fallback 替换为渐变/纯色**

- 详情页 fallback：使用 app 主题色渐变背景 + 半透明遮罩
- 卡片页 fallback：同上
- 当 blur 就绪后，300ms AnimatedSwitcher cross-fade 过渡
- 预期产物：不再出现"闪清晰图"

### Step 8: 旧数据迁移
**App 启动时后台低优先级迁移**

- 入口：`app.dart` (L55 附近) 现有预热流程
- 启动后低优先级遍历角色列表，检查 blur 文件是否存在
- 仅处理本地/base64/asset 图片角色
- 控制并发（一次最多 2 个），避免启动卡顿
- 网络图延后，由首访懒生成
- 预期产物：老用户升级后逐步补齐 blur 文件

### Step 9: 清理旧代码
**移除不再需要的旧模块**

- 评估 `BlurredBackgroundCache` 是否可完全移除
- 评估 `BlurredBackgroundManager` 是否可完全移除
- 清理详情页中的 `_buildGeneratedBackgroundImage` 等旧 fallback 方法
- 预期产物：代码简化，单一职责

### Step 10: 验证
**flutter run 验证**

- 新建角色 → 保存后检查 blur 文件生成
- 打开详情页 → 确认无"闪清晰图"
- 已有角色 → 确认迁移逻辑工作
- 卡片页与详情页视觉一致
- 预期产物：通过验证

## 关键文件

| 文件 | 操作 | 说明 |
|------|------|------|
| blurred_background_cache.dart | 重构/移除 | 内存级缓存 → 合并到统一服务 |
| blurred_background_manager.dart | 重构/移除 | 文件级缓存 → 合并到统一服务 |
| 新文件（或重构后的统一服务） | 新建/重构 | 统一 blur 服务 |
| conversation_providers.dart:L130 | 修改 | 保存后触发 ensureBlur |
| conversation_importer.dart:L505 | 修改 | 导入后触发 ensureBlur |
| sync_service.dart:L163 | 修改 | 同步后触发 ensureBlur |
| character_detail_page.dart:L79,L245,L296 | 修改 | 消费统一服务 + 改 fallback |
| horizontal_role_card.dart:L71 | 修改 | 消费统一服务 |
| app.dart:L55 | 修改 | 旧数据迁移入口 |
| avatar_helper.dart:L188 | 参考 | 图片源类型处理 |

## 风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| 磁盘占用累积 | JPEG 65% quality + 480px，单张约 30-50KB；定期清理未引用文件 |
| 网络图保存时拿不到 | 不阻塞保存，走 pending + fallback |
| 保存后立刻打开详情页（竞态） | 统一服务保留 in-flight 去重 + 原子写入 |
| 角色图被原地替换（路径不变内容变） | source fingerprint 可选加入内容 hash |
| 导出格式变化 | 不导出 blur 文件，导入方自行生成 |

## SESSION_ID（供 /ccg:codex-exec 使用）
- CODEX_SESSION: 019ced88-3701-7aa0-ae92-b805ca1dfa2a
- GEMINI_SESSION: 8798dfe4-1b59-4a2f-9470-2abe36994a56
