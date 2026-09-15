/// 聊天活跃区 sliver 的布局期贴底修正。
///
/// `reverse: true` + `center` 双 sliver 列表里，活跃区（center 之前，
/// GrowthDirection.reverse）内容长高时 `minScrollExtent` 变小而 `pixels`
/// 不变，这一帧会先画出「新内容被推到底部之外」的画面，再由帖后的
/// `jumpTo` 补位——流式每次增长都是「错一帧→跳一下」。这里把补位提前到
/// 布局期：sliver 上报 `scrollOffsetCorrection`，viewport 在同一帧内修正
/// `pixels` 后重新布局，用户看到的第一帧就已经贴底。
///
/// 修正只在 [ChatEndAnchorController.arm] 之后生效，且「是否该跟随」的
/// 裁决完全留在 widget 层（贴底时新 AI 消息不拉底等产品规则不在此处
/// 判断）：widget 层在原本会调度帖后稳底的地方 arm，会打断跟随的事件
/// （用户手势、历史分页、不跟随的结构变化）disarm。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 贴底修正的开关与生命周期。
///
/// arm 后保持到「一帧内没有发生修正」的帖后时刻自动解除；[isHoldActive]
/// 返回 true（如入场动画进行中）时延长保持，让逐帧长高的动画全程贴底。
class ChatEndAnchorController {
  ChatEndAnchorController({bool Function()? isHoldActive})
      : _isHoldActive = isHoldActive ?? _neverHold;

  static bool _neverHold() => false;

  final bool Function() _isHoldActive;
  bool _armed = false;
  bool _correctedThisFrame = false;
  bool _disarmScheduled = false;

  bool get isArmed => _armed;

  /// 允许接下来的布局把活跃区末端修正到视口底部。重复调用幂等。
  void arm() {
    _armed = true;
    _scheduleAutoDisarm();
  }

  void disarm() {
    _armed = false;
    _correctedThisFrame = false;
  }

  void _scheduleAutoDisarm() {
    if (_disarmScheduled) return;
    _disarmScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _disarmScheduled = false;
      // 同帧多次 arm 共用这个回调，读取最新状态；不能因为序号变了
      // 就退出却忘记给新一次 arm 安排解除（会永久残留 armed）。
      if (!_armed) return;
      final corrected = _correctedThisFrame;
      _correctedThisFrame = false;
      if (corrected || _isHoldActive()) {
        _scheduleAutoDisarm();
        return;
      }
      _armed = false;
    });
  }

  void _markCorrected() {
    _correctedThisFrame = true;
  }
}

/// 包在活跃区 sliver 外层，按 [controller] 状态上报 scrollOffsetCorrection。
class ChatEndAnchoredSliver extends SingleChildRenderObjectWidget {
  const ChatEndAnchoredSliver({
    super.key,
    required this.controller,
    required Widget sliver,
  }) : super(child: sliver);

  final ChatEndAnchorController controller;

  @override
  RenderChatEndAnchoredSliver createRenderObject(BuildContext context) {
    return RenderChatEndAnchoredSliver(controller: controller);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderChatEndAnchoredSliver renderObject,
  ) {
    renderObject.controller = controller;
  }
}

class RenderChatEndAnchoredSliver extends RenderProxySliver {
  RenderChatEndAnchoredSliver({required ChatEndAnchorController controller})
      : _controller = controller;

  static const double _kTolerance = 0.5;

  ChatEndAnchorController _controller;
  ChatEndAnchorController get controller => _controller;
  set controller(ChatEndAnchorController value) {
    if (identical(_controller, value)) return;
    _controller = value;
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      geometry = SliverGeometry.zero;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    final childGeometry = child.geometry!;
    if (_controller._armed &&
        constraints.growthDirection == GrowthDirection.reverse) {
      // reverse 增长的 sliver 可见窗口终点 = scrollOffset + remainingPaintExtent
      // （= centerOffset，对唯一的 center 前 sliver 恒成立）。末端与窗口终点
      // 的差就是原本帖后 jumpTo(minScrollExtent) 要补的位移，改为同帧修正。
      // correction 以本 sliver 自身的 scroll 空间表达（正值＝向本 sliver 深处
      // 滚），RenderViewport 对 center 前的 sliver 会自行取反。
      final visibleEnd =
          constraints.scrollOffset + constraints.remainingPaintExtent;
      final gap = childGeometry.scrollExtent - visibleEnd;
      if (gap.abs() > _kTolerance) {
        _controller._markCorrected();
        geometry = SliverGeometry(scrollOffsetCorrection: gap);
        return;
      }
    }
    geometry = childGeometry;
  }
}
