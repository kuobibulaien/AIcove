# 联网搜索插件（2026-10-04）

让聊天模型通过 Function Calling 调用外部搜索供应商。决策见 ADR0056。

## 边界

- 插件 id `web_search`，提供两个工具：`web_search`（搜索并带回正文摘录）、`web_fetch`（读取指定网页正文，最多 5 个 http/https 链接）。
- 只走工具调用：没有可用供应商时插件不生效；模型不支持工具或预设关闭工具调用时同样不生效。不注入系统提示词。
- 工具归属登记在 `firstPartyContentTagProviders`（ADR0044）：角色关闭本插件时，历史里的搜索调用与结果成对移出请求副本，raw 原文不改。
- 角色级开关沿用插件选择（`enabledPlugins`）；全局配置存 `aicove.plugins.web_search.config`，随云同步（含供应商密钥，与模型渠道同口径）。

## 搜索供应商

设置 → 插件 → 联网搜索。供应商是有序列表：长按拖动排序，第一家可用的“优先使用”，其余“备用”；搜索失败自动换下一家，全部失败时把每家原因作为工具结果交还模型。

| 类型 | 接口 | 读网页 |
|---|---|---|
| Exa | `POST /search`、`/contents`，`x-api-key` | 有 |
| Tavily | `POST /search`、`/extract`，Bearer | 有 |
| Brave Search | `GET /res/v1/web/search`，`X-Subscription-Token` | — |
| 博查 | `POST /v1/web-search`，Bearer | — |
| 智谱 | `POST /paas/v4/web_search`（`search_std`），Bearer | — |
| Perplexity | `POST /search`，Bearer | — |
| Jina | `GET s.jina.ai/?q=`；读网页 `r.jina.ai/<url>` | 有 |
| Firecrawl | `POST /v2/search`、`/v2/scrape`，Bearer | 有 |
| Serper（Google） | `POST /search`，`X-API-KEY` | — |
| SearXNG（自建） | `GET /search?format=json`，地址必填、密钥可选 | — |

`web_fetch` 先按顺序用“有读网页接口”的供应商，都不可用时直接下载网页粗提正文（来源标“直接读取”）。

新增供应商：在 `WebSearchProviderType` 加一项，写一个 `WebSearchAdapter` 实现并在 `createWebSearchAdapter` 分发；界面与插件不用改。

## 关闭模型内置搜索

设置页最顶部开关「关闭模型内置搜索，改用此工具」（`replaceModelBuiltinSearch`）。本轮插件生效、开关打开且模型支持工具时，请求出口 `stripBuiltinWebSearch` 去掉各家内置搜索字段（清单见 `core/api/providers/builtin_web_search_suppressor.dart`），普通函数工具不动。模型名自带搜索（`*-search-preview`、`:online`、Sonar 等）无法通过请求体关闭。

开关关闭时不做任何处理：插件工具照常提供，模型内置搜索是否开启由渠道/模型自身决定。

## 代码位置

| 文件 | 职责 |
|---|---|
| `lib/src/features/plugins/web_search/web_search_config.dart` | 供应商类型、供应商条目、插件配置与旧格式迁移 |
| `lib/src/features/plugins/web_search/web_search_adapter.dart` | `WebSearchAdapter` 接口、10 家实现、直接读网页兜底 |
| `lib/src/features/plugins/web_search/web_search_service.dart` | 按顺序调用与失败切换 |
| `lib/src/features/plugins/web_search/web_search_plugin.dart` | 工具定义、参数校验 |
| `lib/src/core/api/providers/builtin_web_search_suppressor.dart` | 剥离模型内置搜索字段 |
| `lib/src/ui/features/plugins/pages/web_search_plugin_detail_page.dart` | 主设置页、供应商列表、添加弹窗 |
| `lib/src/ui/features/plugins/pages/web_search_provider_detail_page.dart` | 单个供应商：启用、名称、密钥、地址、测试、删除 |

## 验证

- 离线：`test/features/plugins/web_search/`、`test/core/api/providers/builtin_web_search_suppressor_test.dart`、`test/ui/features/plugins/web_search_plugin_detail_page_test.dart`。
- 各供应商的请求格式按官方文档编写，用模拟响应测试；真实供应商请求与实机聊天调用尚未验证。
