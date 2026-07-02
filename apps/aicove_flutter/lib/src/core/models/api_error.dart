/// API错误类
/// 统一的错误表示，遵循单一职责原则(S)
class ApiError implements Exception {
  /// 错误消息
  final String message;

  /// HTTP状态码
  final int? statusCode;

  /// 错误代码（provider特定）
  final String? errorCode;

  /// 原始错误（用于调试）
  final dynamic originalError;

  /// 是否可重试
  final bool isRetryable;

  const ApiError({
    required this.message,
    this.statusCode,
    this.errorCode,
    this.originalError,
    this.isRetryable = false,
  });

  /// 创建网络错误
  factory ApiError.network(String message, {dynamic originalError}) {
    return ApiError(
      message: message,
      originalError: originalError,
      isRetryable: true,
    );
  }

  /// 创建认证错误
  factory ApiError.auth(String message, {int? statusCode}) {
    return ApiError(
      message: message,
      statusCode: statusCode ?? 401,
      isRetryable: false,
    );
  }

  /// 创建限流错误
  factory ApiError.rateLimit(String message, {int? statusCode}) {
    return ApiError(
      message: message,
      statusCode: statusCode ?? 429,
      isRetryable: true,
    );
  }

  /// 创建服务器错误
  factory ApiError.server(String message, {int? statusCode, dynamic originalError}) {
    return ApiError(
      message: message,
      statusCode: statusCode ?? 500,
      originalError: originalError,
      isRetryable: true,
    );
  }

  /// 创建客户端错误
  factory ApiError.client(String message, {int? statusCode}) {
    return ApiError(
      message: message,
      statusCode: statusCode ?? 400,
      isRetryable: false,
    );
  }

  @override
  String toString() {
    final parts = <String>['ApiError: $message'];
    if (statusCode != null) parts.add('(HTTP $statusCode)');
    if (errorCode != null) parts.add('[Code: $errorCode]');
    return parts.join(' ');
  }
}
