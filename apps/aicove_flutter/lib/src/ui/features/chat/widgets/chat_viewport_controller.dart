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

  ChatViewportMode get mode => _mode;

  bool get shouldFollowLatest => _mode == ChatViewportMode.followLatest;
  bool get isDetached => _mode == ChatViewportMode.detached;

  int get scrollToBottomRequestSerial => _scrollToBottomRequestSerial;

  void onConversationChanged() {
    _setState(mode: ChatViewportMode.followLatest);
  }

  void onUserGesture() {
    _setState(mode: ChatViewportMode.detached);
  }

  void onHistoryPagingStarted() {
    _setState(mode: ChatViewportMode.detached);
  }

  void onComposerTapped() {}

  void onUserSend() {
    _setState(
      mode: ChatViewportMode.followLatest,
      requestScrollToBottom: true,
    );
  }

  void onJumpToLatest() {
    _setState(
      mode: ChatViewportMode.followLatest,
      requestScrollToBottom: true,
    );
  }

  void onViewportReachedLatest() {
    _setState(mode: ChatViewportMode.followLatest);
  }

  void _setState({
    ChatViewportMode? mode,
    bool requestScrollToBottom = false,
  }) {
    final nextMode = mode ?? _mode;
    final modeChanged = _mode != nextMode;
    if (!modeChanged && !requestScrollToBottom) {
      return;
    }
    _mode = nextMode;
    if (requestScrollToBottom) {
      _scrollToBottomRequestSerial += 1;
    }
    notifyListeners();
  }
}
