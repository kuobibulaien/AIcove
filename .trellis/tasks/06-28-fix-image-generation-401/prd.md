# fix: image generation 401

## Goal

修复真机上图片生成返回 401 的问题，明确错误来源并让生图链路在已配置密钥时可正常请求。

## What I already know

* 用户反馈“图片生成 401”，真机已通过 adb 连接。
* 项目默认开发范围是 `apps/aicove_flutter/`。
* 生图供应商应通过 `ImageProviderAdapter` 接入，不在 UI 层直接写供应商请求。

## Assumptions (temporary)

* 401 可能来自请求头、API key 读取、baseUrl 路由或真机环境配置。
* 本任务优先修复客户端本地生图链路，不修改云端生产数据。

## Open Questions

* 暂无阻塞问题，先从仓库和真机日志自行排查。

## Requirements

* 定位 401 发生在 Flutter 端、后端代理或供应商接口中的哪一层。
* 修复最小必要代码或配置读取逻辑。
* 保持现有 Image Provider Adapter 分层。

## Acceptance Criteria

* [ ] 真机执行图片生成不再因客户端错误产生 401。
* [ ] 错误信息能区分未配置密钥、密钥错误和接口返回 401。
* [ ] `flutter run --no-resident` 可完成验证。

## Definition of Done

* `flutter pub get` 已执行。
* 真机编译运行已验证。
* 若行为或约定变化，更新长期文档；否则说明无需更新。

## Out of Scope

* 不更换生图供应商。
* 不新增全局依赖。
* 不修改生产环境云端数据。

## Technical Notes

* 已读：根 `README.md`、`.trellis/spec/frontend/index.md`、前端目录/状态/质量/类型规范。
