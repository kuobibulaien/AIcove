import 'package:flutter/foundation.dart';

enum ChatViewportMode {
  followLatest,
  detached,
}

/// 统一管理聊天列表的视窗行为。
///
/// 规则：
/// - 用户手势或历史分页触发后，进入 `detached`
/// - 进入 `detached` 后，列表保持当前位置，不再强制滚动
/// - 只有用户主动回到底部、点击“回到底部”或再次发送消息时，才恢复 `followLatest`
class ChatViewportController extends ChangeNotifier {
  ChatViewportMode _mode = ChatViewportMode.followLatest;
  int _scrollToBottomRequestSerial = 0;
  bool _scrollToBottomRequestAnimated = false;
  bool _pinLatestTail = false;

  ChatViewportMode get mode => _mode;

  bool get shouldFollowLatest => _mode == ChatViewportMode.followLatest;
  bool get isDetached => _mode == ChatViewportMode.detached;
  bool get shouldPinLatestTail => shouldFollowLatest && _pinLatestTail;

  int get scrollToBottomRequestSerial => _scrollToBottomRequestSerial;
  bool get scrollToBottomRequestAnimated => _scrollToBottomRequestAnimated;

  void onConversationChanged() {
    _setState(
      mode: ChatViewportMode.followLatest,
      pinLatestTail: false,
    );
  }

  void onUserGesture() {
    _setState(
      mode: ChatViewportMode.detached,
      pinLatestTail: false,
    );
  }

  void onHistoryPagingStarted() {
    _setState(
      mode: ChatViewportMode.detached,
      pinLatestTail: false,
    );
  }

  void onComposerTapped() {}

  void onUserSend() {
    _setState(
      mode: ChatViewportMode.followLatest,
      requestScrollToBottom: true,
      scrollToBottomAnimated: false,
      pinLatestTail: true,
    );
  }

  void onJumpToLatest() {
    _setState(
      mode: ChatViewportMode.followLatest,
      requestScrollToBottom: true,
      scrollToBottomAnimated: true,
      pinLatestTail: true,
    );
  }

  void onViewportReachedLatest() {
    _setState(mode: ChatViewportMode.followLatest);
  }

  void _setState({
    ChatViewportMode? mode,
    bool requestScrollToBottom = false,
    bool scrollToBottomAnimated = false,
    bool? pinLatestTail,
  }) {
    final nextMode = mode ?? _mode;
    final nextPinLatestTail = pinLatestTail ?? _pinLatestTail;
    final modeChanged = _mode != nextMode;
    final pinLatestTailChanged = _pinLatestTail != nextPinLatestTail;
    if (!modeChanged && !requestScrollToBottom && !pinLatestTailChanged) {
      return;
    }
    _mode = nextMode;
    _pinLatestTail = nextPinLatestTail;
    if (requestScrollToBottom) {
      _scrollToBottomRequestAnimated = scrollToBottomAnimated;
      _scrollToBottomRequestSerial += 1;
    }
    notifyListeners();
  }
}
