# Cupertino 页面转场使用指南

页面横向转场规则唯一权威：[界面布局说明「页面转场」](../../界面布局说明.md#页面转场2026-09-14)。本页仅说明调用方式。

普通页面通过 `MoeWorkspace.open(context, page)` 打开，已有详情内部也可调用 `Navigator.of(context).push(ParallaxSlidePageRoute(page: page))`。go_router 的 `pageBuilder` 返回 `ParallaxSlidePage(key: state.pageKey, child: page)`。

`ParallaxSlidePageRoute` / `ParallaxSlidePage` 保留历史名字，只适配工作区背景、同级直接切换及 Page 设置更新；实际动画使用 Flutter 官方 Cupertino。不要传入自写时长、曲线或视差比例，也不再使用已移除的 `ParallaxSlideConfig`、主次位移 helper 或中断轨迹。

窄屏及详情栈内层级跳转采用官方动画；宽屏一级入口切换二级详情仍直接切换。图片预览、裁剪与卡片展开按各自组件语义处理。

验证入口：`test/ui/shared/animations/cupertino_route_parity_test.dart` 比较命令式与 Page 路由在窄宽尺寸、LTR/RTL、提前返回及连续重入中的实际坐标与官方一致；声明式更新、返回手势及工作区退栈另见同目录测试与 `moe_adaptive_shell_test.dart`。坐标一致不是实机帧率保证。
