import 'image_config.dart';

/// 模型仅能覆盖白名单内的参数；非有限数、小数整数和越界值明确拒绝。
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
    int integer(String key, int fallback, int min, int max) {
      final raw = args[key];
      if (raw == null) return fallback;
      final value = raw is num ? raw : num.tryParse(raw.toString());
      if (value == null ||
          !value.isFinite ||
          value != value.roundToDouble() ||
          value < min ||
          value > max) {
        throw FormatException('$key 必须是 $min–$max 的整数');
      }
      return value.toInt();
    }

    double number(String key, double fallback, double min, double max) {
      final raw = args[key];
      if (raw == null) return fallback;
      final value = raw is num
          ? raw.toDouble()
          : double.tryParse(raw.toString());
      if (value == null || !value.isFinite || value < min || value > max) {
        throw FormatException('$key 必须在 $min–$max 之间');
      }
      return value;
    }

    if (!novelAi &&
        !supportsSamplingParameters &&
        (args.containsKey('steps') || args.containsKey('guidance_scale'))) {
      throw const FormatException('当前图片渠道不支持 steps / guidance_scale');
    }
    final result = DrawingParameters(
      width: integer('width', config.defaultWidth, 256, 2048),
      height: integer('height', config.defaultHeight, 256, 2048),
      count: integer('count', config.defaultCount, 1, 4),
      steps: integer('steps', config.defaultSteps, 1, 100),
      guidanceScale: number(
        'guidance_scale',
        config.defaultGuidanceScale,
        0,
        10,
      ),
    );
    if (novelAi && (result.width % 64 != 0 || result.height % 64 != 0)) {
      throw const FormatException('NovelAI 宽高必须是 64 的倍数');
    }
    return result;
  }
}
