# 0034 公共滑块组件 MoeSlider

- 日期：2026-09-15
- 状态：accepted
- 用户决定：重写滑块公共类，无极调节、轨道上不画点，采用更高级的滑块样式。

## 决定与边界

用户侧所有数值滑块统一使用 `MoeSlider`（`lib/src/ui/shared/widgets/form/moe_slider.dart`，经 `widgets/index.dart` 导出）。交互层仍是 Flutter `Slider`（手势、语义、键盘不变），外观由自绘 `SliderTrackShape` 与 `SliderComponentShape` 承担：

- 胶囊轨道永不渲染刻度点；`divisions` 仅保留吸附语义，不传即无极调节。
- 激活段为强调色纵向微光泽渐变；悬浮圆钮带柔和投影，浅色取表面色、深色取近白色，按下时轻微放大。
- 取色一律来自 `MoeColors`（accentColor 系），调用方不再各自传 `activeColor`/`overlayColor`。

材质等级的玻璃厚度由三档吸附改为 0~32 连续 sigma；`MoeGlassThickness` 三档仅作刻度文案与最近档高亮，`app.dart` 的 `MoeGlassTheme.blurSigma` 直接传原始值。内部调试页可继续使用裸 `Slider`。

## 代价、验收与回滚

公共外观集中在单个组件内，后续改样式只动一处；无极 sigma 让渲染强度逐点可调，放弃了三档语义与存储值的一一对应（存储本就为 double，无迁移成本）。通过 `moe_slider_test`（连续值、吸附、无刻度点、禁用态）与设置页相关回归验证；源码渲染预览见 `.codex-temp/material-levels/`、`.codex-temp/ui-settings-redesign/`。回滚为恢复相关文件快照，无数据或依赖变更。
