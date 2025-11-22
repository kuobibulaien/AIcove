import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/api_client.dart';
import '../models/user_model.dart';

/// 认证状态
class AuthState {
  final UserModel? user;
  final bool isLoggedIn;
  final bool isLoading;
  final String? error;

  AuthState({
    this.user,
    this.isLoggedIn = false,
    this.isLoading = false,
    this.error,
  });

  AuthState copyWith({
    UserModel? user,
    bool? isLoggedIn,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      user: user ?? this.user,
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// API客户端Provider
final apiClientProvider = Provider<ApiClient>((ref) {
  // TODO: 从配置读取baseUrl
  const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
  return ApiClient(baseUrl: baseUrl);
});

/// 认证Notifier
class AuthNotifier extends StateNotifier<AuthState> {
  final ApiClient _apiClient;

  AuthNotifier(this._apiClient) : super(AuthState()) {
    // 初始化时检查登录状态
    _checkLoginStatus();
  }

  /// 检查登录状态
  Future<void> _checkLoginStatus() async {
    final isLoggedIn = await _apiClient.isLoggedIn();
    if (isLoggedIn) {
      // 尝试获取用户信息
      try {
        final userData = await _apiClient.getCurrentUser();
        final user = UserModel.fromJson(userData);
        state = state.copyWith(user: user, isLoggedIn: true);
      } catch (e) {
        // Token可能过期，清除
        await _apiClient.clearToken();
        state = state.copyWith(isLoggedIn: false);
      }
    }
  }

  /// 登录
  Future<bool> login({
    required String username,
    required String password,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _apiClient.login(
        username: username,
        password: password,
      );

      final authResponse = AuthResponse.fromJson(response);

      // 保存Token
      await _apiClient.saveToken(authResponse.accessToken);

      // 更新状态
      state = state.copyWith(
        user: authResponse.user,
        isLoggedIn: true,
        isLoading: false,
      );

      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '登录失败: ${e.toString()}',
      );
      return false;
    }
  }

  /// 注册
  Future<bool> register({
    required String username,
    required String password,
    String? email,
    String? inviteCode,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _apiClient.register(
        username: username,
        password: password,
        email: email,
        inviteCode: inviteCode,
      );

      final authResponse = AuthResponse.fromJson(response);

      // 保存Token
      await _apiClient.saveToken(authResponse.accessToken);

      // 更新状态
      state = state.copyWith(
        user: authResponse.user,
        isLoggedIn: true,
        isLoading: false,
      );

      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '注册失败: ${e.toString()}',
      );
      return false;
    }
  }

  /// 登出
  Future<void> logout() async {
    await _apiClient.clearToken();
    state = AuthState();
  }

  /// 清除错误
  void clearError() {
    state = state.copyWith(error: null);
  }
}

/// 认证Provider
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AuthNotifier(apiClient);
});
