import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API客户端
class ApiClient {
  final Dio _dio;
  final FlutterSecureStorage _storage;
  final String baseUrl;

  ApiClient({
    required this.baseUrl,
    FlutterSecureStorage? storage,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 30),
            headers: {
              'Content-Type': 'application/json',
            },
          ),
        ) {
    // 添加认证拦截器
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // 自动添加Token
          final token = await _storage.read(key: 'access_token');
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          return handler.next(options);
        },
        onError: (error, handler) async {
          // 401错误：Token过期或无效
          if (error.response?.statusCode == 401) {
            // 清除Token
            await _storage.delete(key: 'access_token');
          }
          return handler.next(error);
        },
      ),
    );
  }

  // ============ 认证相关 ============

  /// 注册
  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    String? email,
    String? inviteCode,
  }) async {
    final response = await _dio.post(
      '/api/v1/auth/register',
      data: {
        'username': username,
        'password': password,
        if (email != null) 'email': email,
        if (inviteCode != null) 'invite_code': inviteCode,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// 登录
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    final response = await _dio.post(
      '/api/v1/auth/login',
      data: {
        'username': username,
        'password': password,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// 获取当前用户信息
  Future<Map<String, dynamic>> getCurrentUser() async {
    final response = await _dio.get('/api/v1/auth/me');
    return response.data as Map<String, dynamic>;
  }

  // ============ 同步相关 ============

  /// 获取联系人
  Future<Map<String, dynamic>> getContacts({String? since}) async {
    final response = await _dio.get(
      '/api/v1/sync/contacts',
      queryParameters: {
        if (since != null) 'since': since,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// 批量同步联系人
  Future<Map<String, dynamic>> syncContacts(
      List<Map<String, dynamic>> items) async {
    final response = await _dio.post(
      '/api/v1/sync/contacts',
      data: {'items': items},
    );
    return response.data as Map<String, dynamic>;
  }

  /// 删除联系人
  Future<void> deleteContact(String contactId) async {
    await _dio.delete('/api/v1/sync/contacts/$contactId');
  }

  /// 获取消息
  Future<Map<String, dynamic>> getMessages({
    String? contactId,
    String? since,
    int limit = 100,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      '/api/v1/sync/messages',
      queryParameters: {
        if (contactId != null) 'contact_id': contactId,
        if (since != null) 'since': since,
        'limit': limit,
        'offset': offset,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// 批量同步消息
  Future<Map<String, dynamic>> syncMessages(
      List<Map<String, dynamic>> items) async {
    final response = await _dio.post(
      '/api/v1/sync/messages',
      data: {'items': items},
    );
    return response.data as Map<String, dynamic>;
  }

  /// 获取用户设置
  Future<Map<String, dynamic>> getSettings() async {
    final response = await _dio.get('/api/v1/sync/settings');
    return response.data as Map<String, dynamic>;
  }

  /// 更新用户设置
  Future<Map<String, dynamic>> updateSettings(
      Map<String, dynamic> settings) async {
    final response = await _dio.put(
      '/api/v1/sync/settings',
      data: {'settings': settings},
    );
    return response.data as Map<String, dynamic>;
  }

  /// 获取同步状态
  Future<Map<String, dynamic>> getSyncStatus() async {
    final response = await _dio.get('/api/v1/sync/status');
    return response.data as Map<String, dynamic>;
  }

  // ============ Token管理 ============

  /// 保存Token
  Future<void> saveToken(String token) async {
    await _storage.write(key: 'access_token', value: token);
  }

  /// 获取Token
  Future<String?> getToken() async {
    return await _storage.read(key: 'access_token');
  }

  /// 清除Token
  Future<void> clearToken() async {
    await _storage.delete(key: 'access_token');
  }

  /// 检查是否已登录
  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }
}
