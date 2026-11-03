import '../../../core/app_logger.dart';
import 'image_config.dart';

/// 模型可覆盖白名单参数；有限数值自动归一化，无法解析的值明确拒绝。
class DrawingParameters {
  final int width, height, steps, count;
  final double guidanceScale;

  const DrawingParameters({
    required this.width,
    required this.height,
    required this.steps,
    required this.count,
    required this.guidanceScale,
  });

  factory DrawingParameters.resolve(
    ImageConfig config,
    Map<String, dynamic> args, {
    required bool novelAi,
    bool supportsSamplingParameters = false,
  }) {
    final effectiveArgs = Map<String, dynamic>.from(args);
    if (!novelAi &&
        !supportsSamplingParameters &&
        (args.containsKey('steps') || args.containsKey('guidance_scale'))) {
      effectiveArgs.remove('steps');
      effectiveArgs.remove('guidance_scale');
      AppLogger.info('DrawingParameters', '当前图片渠道忽略 steps / guidance_scale');
    }

    num finiteNumber(String key, num fallback, String errorMessage) {
      final raw = effectiveArgs[key] ?? fallback;
      final value = raw is num ? raw : num.tryParse(raw.toString());
      if (value == null || !value.isFinite) {
        throw FormatException(errorMessage);
      }
      return value;
    }

    int integer(String key, int fallback, int min, int max) => finiteNumber(
      key,
      fallback,
      '$key 必须是 $min–$max 的整数',
    ).round().clamp(min, max);

    int dimension(String key, int fallback) {
      final value = integer(key, fallback, 256, 2048);
      return novelAi ? ((value / 64).round() * 64).clamp(256, 2048) : value;
    }

    return DrawingParameters(
      width: dimension('width', config.defaultWidth),
      height: dimension('height', config.defaultHeight),
      count: integer('count', config.defaultCount, 1, 4),
      steps: integer('steps', config.defaultSteps, 1, 100),
      guidanceScale: finiteNumber(
        'guidance_scale',
        config.defaultGuidanceScale,
        'guidance_scale 必须在 0.0–20.0 之间',
      ).toDouble().clamp(0, 20),
    );
  }
}
