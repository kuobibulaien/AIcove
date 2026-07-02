# State Management

## 状态分类

| 类型 | 放置建议 |
|---|---|
| 页面临时状态 | Widget local state |
| 跨页面业务状态 | Riverpod provider |
| 持久化真相源 | Drift / SQLite / repository |
| 云同步状态 | cloud sync service / repository |
| Agent 运行状态 | Agent Runtime / Scheduler 契约 |

## 聊天状态

- DB raw message 是聊天上下文唯一真相源。
- UI 气泡、短列表缓存、投影服务只能用于展示，不得作为模型上下文。
- 删除仅前端可见时，遵循相关实施说明，不能直接污染 raw DB。

## 缓存

缓存只能服务性能和展示，不能替代权威数据源。新增缓存时必须说明失效策略和回退路径。

## 模型类型配置

- 模型类型自动推断只能作为缺省值，不能覆盖用户显式选择。
- 当用户把自动推断为非 `chat` 的模型手动改成 `chat` 时，仍必须在 `model_types` 中保存显式 `chat`，否则下一次读取会重新回到错误推断。
- TTS 音色名（如 `fable`、`alloy`、`nova`）只能在完整模型 ID 精确等于音色名时推断为 `tts`，不要用子串匹配判断聊天模型名。

