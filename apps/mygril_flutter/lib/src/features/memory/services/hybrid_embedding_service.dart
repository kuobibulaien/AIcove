import '../../../core/app_logger.dart';
import 'embedding_service.dart';
import 'openai_embedding_service.dart';

/// 混合嵌入服务
/// 
/// 工作模式：
/// 1. 优先尝试调用主嵌入服务（云端API）
/// 2. 若主服务调用失败且本地降级已启用，则尝试本地嵌入服务
/// 3. 若都失败则抛出异常
/// 
/// 这样设计可以让用户在有网络时享受高质量云端嵌入，
/// 断网时自动降级到本地模型，实现完全离线运行。
class HybridEmbeddingService implements EmbeddingService {
  final EmbeddingService _primaryService;   // 主服务（云端）
  final EmbeddingService? _fallbackService; // 降级服务（本地）
  final bool _fallbackEnabled;

  /// 记录当前是否处于降级模式（用于日志和状态监控）
  bool _isInFallbackMode = false;
  bool get isInFallbackMode => _isInFallbackMode;

  HybridEmbeddingService({
    required String primaryApiKey,
    required String primaryBaseUrl,
    required String primaryModel,
    bool fallbackEnabled = false,
    String fallbackBaseUrl = '',
    String fallbackModel = '',
    String fallbackApiKey = '',
  })  : _fallbackEnabled = fallbackEnabled,
        _primaryService = OpenAIEmbeddingService(
          apiKey: primaryApiKey,
          baseUrl: primaryBaseUrl,
          model: primaryModel,
        ),
        _fallbackService = fallbackEnabled && fallbackBaseUrl.isNotEmpty
            ? OpenAIEmbeddingService(
                apiKey: fallbackApiKey,
                baseUrl: fallbackBaseUrl,
                model: fallbackModel,
              )
            : null;

  @override
  Future<List<double>> getEmbedding(String text) async {
    // 尝试主服务
    try {
      final result = await _primaryService.getEmbedding(text);
      _isInFallbackMode = false;
      return result;
    } catch (primaryError) {
      AppLogger.warning(
        'HybridEmbeddingService',
        'Primary embedding service failed, attempting fallback...',
        metadata: {'error': primaryError.toString()},
      );

      // 尝试降级服务
      if (_fallbackEnabled && _fallbackService != null) {
        try {
          final result = await _fallbackService.getEmbedding(text);
          _isInFallbackMode = true;
          AppLogger.info('HybridEmbeddingService', 'Fallback embedding service succeeded.');
          return result;
        } catch (fallbackError) {
          AppLogger.error(
            'HybridEmbeddingService',
            'Both primary and fallback embedding services failed',
            metadata: {
              'primaryError': primaryError.toString(),
              'fallbackError': fallbackError.toString(),
            },
          );
          throw Exception(
            'Embedding failed: Primary error: $primaryError, Fallback error: $fallbackError',
          );
        }
      } else {
        // 降级未启用，直接抛出主服务错误
        rethrow;
      }
    }
  }

  @override
  Future<List<List<double>>> getEmbeddings(List<String> texts) async {
    // 尝试主服务
    try {
      final result = await _primaryService.getEmbeddings(texts);
      _isInFallbackMode = false;
      return result;
    } catch (primaryError) {
      AppLogger.warning(
        'HybridEmbeddingService',
        'Primary embedding service failed for batch, attempting fallback...',
        metadata: {'error': primaryError.toString(), 'count': texts.length},
      );

      // 尝试降级服务
      if (_fallbackEnabled && _fallbackService != null) {
        try {
          final result = await _fallbackService.getEmbeddings(texts);
          _isInFallbackMode = true;
          AppLogger.info('HybridEmbeddingService', 'Fallback embedding service succeeded for batch.');
          return result;
        } catch (fallbackError) {
          AppLogger.error(
            'HybridEmbeddingService',
            'Both services failed for batch embedding',
            metadata: {
              'primaryError': primaryError.toString(),
              'fallbackError': fallbackError.toString(),
            },
          );
          throw Exception(
            'Batch embedding failed: Primary error: $primaryError, Fallback error: $fallbackError',
          );
        }
      } else {
        rethrow;
      }
    }
  }
}
