import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api_client.dart';
import '../../../core/api/providers/token_usage.dart';
import '../../settings/settings_models.dart';

part 'official_pricing_sync.dart';

/// 单价单位为每百万 Token；金额按原币种计算，不进行汇率换算。
class ModelPricing {
  const ModelPricing({
    required this.inputPricePerMillion,
    required this.outputPricePerMillion,
    this.cachedInputPricePerMillion,
    this.cacheWritePricePerMillion,
    this.currency = 'USD',
    this.multiplier = 1.0,
    this.isBuiltinReference = false,
  });

  final double inputPricePerMillion;
  final double outputPricePerMillion;
  final double? cachedInputPricePerMillion;
  final double? cacheWritePricePerMillion;
  final String currency;
  final double multiplier;
  final bool isBuiltinReference;
}

class _PriceRule {
  const _PriceRule(
    this.prefixes,
    this.input,
    this.output,
    this.cached, {
    this.currency = 'USD',
    this.write,
  });

  final List<String> prefixes;
  final double input;
  final double output;
  final double cached;
  final double? write;
  final String currency;
}

// ADR0129 的内置参考目录。按最长匹配选择，避免 mini/nano/flash 被主型号吞掉。
const _rules = <_PriceRule>[
  _PriceRule(['gpt-5.1'], 1.25, 10, .125),
  _PriceRule(['gpt-5.2', 'gpt-5.3-codex'], 1.75, 14, .175),
  _PriceRule(['gpt-5.4-nano'], .2, 1.25, .02),
  _PriceRule(['gpt-5.4-mini'], .75, 4.5, .075),
  _PriceRule(['gpt-5.4'], 2.5, 15, .25),
  _PriceRule(['gpt-5.5'], 5, 30, .5),
  _PriceRule(['gpt-5-pro'], 15, 120, 1.5),
  _PriceRule(['gpt-5.2-pro'], 21, 168, 2.1),
  _PriceRule(['gpt-5.4-pro', 'gpt-5.5-pro'], 30, 180, 3),
  _PriceRule(['gpt-5.6-luna'], .2, 1.2, .02, write: .25),
  _PriceRule(['gpt-5.6-terra'], 2, 12, .2, write: 2.5),
  _PriceRule(['gpt-5.6'], 4, 20, .4, write: 5),
  _PriceRule(['gpt-6-luna'], .1, .5, .01, write: .125),
  _PriceRule(['gpt-6.1-terra'], 1, 5, .05, write: 1.25),
  _PriceRule(
    ['gpt-6-sol', 'gpt-6.1-sol', 'gpt-6.2-sol'],
    2,
    10,
    .1,
    write: 2.5,
  ),
  _PriceRule(['gpt-6.2-astra'], 8, 40, .4, write: 10),
  _PriceRule(['gpt-6-astra'], 10, 50, 1, write: 12.5),
  _PriceRule(['gpt-5-nano'], .05, .40, .005),
  _PriceRule(['gpt-5-mini'], .25, 2, .025),
  _PriceRule(['gpt-5'], 1.25, 10, .125),
  _PriceRule(['gpt-4.1-nano'], .1, .4, .025),
  _PriceRule(['gpt-4.1-mini'], .4, 1.6, .1),
  _PriceRule(['gpt-4.1'], 2, 8, .5),
  _PriceRule(['gpt-4o-mini'], .15, .6, .075),
  _PriceRule(['gpt-4o'], 2.5, 10, 1.25),
  _PriceRule(['o4-mini', 'o3-mini'], 1.1, 4.4, .275),
  _PriceRule(['o3'], 2, 8, .5),
  _PriceRule(['claude-opus-5-5'], 4, 20, .2, write: 5),
  _PriceRule(['claude-fable-5-2'], 8, 40, .2, write: 10),
  _PriceRule(['claude-fable-5', 'claude-fable-5-1'], 10, 50, .25, write: 12.5),
  _PriceRule(['claude-sonnet-5', 'claude-sonnet-5-5'], 2, 10, .2, write: 2.5),
  _PriceRule(['claude-haiku-5-5'], .1, .5, .01, write: .125),
  _PriceRule(
    [
      'claude-opus-4-5',
      'claude-opus-4-6',
      'claude-opus-4-7',
      'claude-opus-4-8',
      'claude-opus-5',
    ],
    5,
    25,
    .5,
    write: 6.25,
  ),
  _PriceRule(['claude-opus-4', 'claude-4-opus'], 15, 75, 1.5, write: 18.75),
  _PriceRule(
    [
      'claude-sonnet-4',
      'claude-sonnet-4-5',
      'claude-sonnet-4-6',
      'claude-4-sonnet',
      'claude-3-7-sonnet',
      'claude-3-5-sonnet',
    ],
    3,
    15,
    .3,
    write: 3.75,
  ),
  _PriceRule(
    ['claude-haiku-4', 'claude-haiku-4-5', 'claude-4-haiku'],
    1,
    5,
    .1,
    write: 1.25,
  ),
  _PriceRule(['claude-3-5-haiku'], .8, 4, .08, write: 1),
  _PriceRule(['gemini-2.0-flash-lite'], .075, .3, .01875),
  _PriceRule(['gemini-3.5-flash-lite'], .3, 2.5, .03),
  _PriceRule(['gemini-3.5-flash'], 1.5, 9, .15),
  _PriceRule(
    ['gemini-3.6-flash', 'gemini-3.7-flash', 'gemini-3.8-flash'],
    .75,
    3.75,
    .075,
  ),
  _PriceRule(['gemini-4-hydrogen'], 1.5, 7.5, .075),
  _PriceRule(['gemini-4-argon', 'gemini-4-carbon', 'gemini-4'], 2, 10, .1),
  _PriceRule(['gemini-2.5-flash-lite', 'gemini-3.1-flash-lite'], .1, .4, .025),
  _PriceRule(
    ['gemini-2.5-flash', 'gemini-3-flash', 'gemini-3.1-flash'],
    .3,
    2.5,
    .075,
  ),
  _PriceRule(['gemini-2.0-flash'], .1, .4, .025),
  _PriceRule(['gemini-2.5-pro'], 1.25, 10, .3125),
  _PriceRule(['gemini-3-pro', 'gemini-3.1-pro'], 2, 12, .2),
  _PriceRule(['deepseek-v4-pro'], 4.8, 14.4, .16, currency: 'CNY'),
  _PriceRule(
    ['deepseek-flash', 'deepseek-v4.1-flash', 'deepseek-v4-flash'],
    .5,
    2,
    .1,
    currency: 'CNY',
  ),
  _PriceRule(
    ['deepseek-chat', 'deepseek-v3', 'deepseek-v4'],
    2,
    8,
    .5,
    currency: 'CNY',
  ),
  _PriceRule(['deepseek-reasoner', 'deepseek-r1'], 4, 16, 1, currency: 'CNY'),
  _PriceRule(
    [
      'qwen-flash',
      'qwen3.5-flash',
      'qwen3.6-flash',
      'qwen3.7-flash',
      'qwen3.8-flash',
      'qwen3.8-omni-flash',
      'qwen3-omni-flash',
      'qwen3-coder-flash',
    ],
    .3,
    1.2,
    .06,
    currency: 'CNY',
  ),
  _PriceRule(
    ['qwen3-max', 'qwen3.6-max', 'qwen3.7-max', 'qwen3.8-max'],
    14,
    42,
    2.8,
    currency: 'CNY',
  ),
  _PriceRule(
    ['qwen3.5-plus', 'qwen3.6-plus', 'qwen3.7-plus', 'qwen3.8-plus', 'qwq'],
    2.8,
    12,
    .56,
    currency: 'CNY',
  ),
  _PriceRule(['qwen-turbo'], .3, .6, .06, currency: 'CNY'),
  _PriceRule(['qwen-plus', 'qwen3-'], .8, 2, .16, currency: 'CNY'),
  _PriceRule(['qwen-max'], 2.4, 9.6, .48, currency: 'CNY'),
  _PriceRule(
    ['kimi-k2.5', 'kimi-k2.6', 'kimi-k2.7'],
    6.8,
    28,
    1.1,
    currency: 'CNY',
  ),
  _PriceRule(['kimi-k3.1-pro'], 14, 70, 1.4, currency: 'CNY'),
  _PriceRule(['kimi-k3'], 20, 100, 2, currency: 'CNY'),
  _PriceRule(['kimi-k2', 'moonshot-'], 4, 16, 1, currency: 'CNY'),
  _PriceRule(['glm-4.7-flash', 'glm-4.6v-flash'], 0, 0, 0, currency: 'CNY'),
  _PriceRule(
    ['glm-4.7-flashx', 'glm-4.5-air', 'glm-5.3-flash'],
    .8,
    2.8,
    .2,
    currency: 'CNY',
  ),
  _PriceRule(['glm-5.3-flashx'], 2, 7, .5, currency: 'CNY'),
  _PriceRule(['glm-4.7'], 3, 14, .6, currency: 'CNY'),
  _PriceRule(['glm-5-turbo', 'glm-5.1'], 6, 24, 1.3, currency: 'CNY'),
  _PriceRule(['glm-5.2', 'glm-5.3'], 8, 28, 2, currency: 'CNY'),
  _PriceRule(['glm-4-flash', 'glm-4.5-flash'], .1, .1, .02, currency: 'CNY'),
  _PriceRule(
    ['glm-4', 'glm-4.5', 'glm-4.6', 'glm-5'],
    4,
    16,
    1,
    currency: 'CNY',
  ),
  _PriceRule(['minimax-m3.1-flash'], 1, 4, .1, currency: 'CNY'),
  _PriceRule(['minimax-m', 'abab'], 1, 4, .2, currency: 'CNY'),
  _PriceRule(
    ['doubao-seed-1-6-flash', 'doubao-seed-2-0-mini'],
    .15,
    1.5,
    .03,
    currency: 'CNY',
  ),
  _PriceRule(['doubao-seed-2-0-lite'], .6, 3.6, .12, currency: 'CNY'),
  _PriceRule(
    ['doubao-seed-1-6', 'doubao-seed-1-8'],
    .8,
    8,
    .16,
    currency: 'CNY',
  ),
  _PriceRule(
    ['doubao-seed-2-0-pro', 'doubao-seed-2-1-turbo'],
    3.2,
    16,
    .64,
    currency: 'CNY',
  ),
  _PriceRule(['doubao-seed-2-1-pro'], 6, 30, 1.2, currency: 'CNY'),
  _PriceRule(['mimo-v2.5-pro-ultraspeed'], 9, 18, .08, currency: 'CNY'),
  _PriceRule(['mimo-v2.6-pro-ultraspeed'], 30, 60, .25, currency: 'CNY'),
  _PriceRule(['mimo-v2.5-pro', 'mimo-v2.6-pro'], 3, 6, .03, currency: 'CNY'),
  _PriceRule(['mimo-v2.5', 'mimo-v2.6-flash'], 1, 2, .02, currency: 'CNY'),
  _PriceRule(['step-3.5-flash'], .7, 2.1, .14, currency: 'CNY'),
  _PriceRule(['step-3.7-flash'], 1.4, 8.5, .28, currency: 'CNY'),
  _PriceRule(['step-5'], 7, 20, .7, currency: 'CNY'),
  _PriceRule(
    ['muse-spark-1.2-contributor', 'muse-spark-1.3-contributor'],
    .1,
    .2,
    .002,
  ),
  _PriceRule(['muse-spark-1'], 1.25, 4.25, .15),
  _PriceRule(['mercury-3'], .1, .35, .01),
  _PriceRule(['mercury-2.5'], .2, .75, .02),
  _PriceRule(['mercury-2'], .25, .75, .025),
  _PriceRule(['grok-4.20', 'grok-4.3'], 1.25, 2.5, .2),
  _PriceRule(['grok-4', 'grok-4.5', 'grok-4.6', 'grok-4.7'], 2, 6, .5),
];

const _routeTags = {
  'free',
  'exacto',
  'nitro',
  'beta',
  'floor',
  'online',
  'low-cost',
  'extended',
};
final _removableRoute = RegExp(r':(?:exacto|nitro|beta|floor|online)$');
final _relayPrefix = RegExp(
  r'^(?:假流式|流式|抗截断|逆向|官转|直连|特惠|满血|高速|vtx|vertex|cmaas|azure)-',
);
final _regionalPrefix = RegExp(
  r'^(?:(?:'
  r'(?:us|eu|ap|europe|asia|africa|australia|northamerica|southamerica|me|il)'
  r'-(?:east|west|central|north|south|northeast|northwest|southeast|southwest)'
  r'(?:-?\d+)?|(?:east|west|central)us\d*|us|eu|global)-)+',
);
const _familyPattern =
    r'(?:claude-|gemini-|gpt-|deepseek-|qwen|kimi-|glm-|grok-|minimax-|'
    r'doubao-|mercury-|muse-spark-|mimo-|step-)';
final _familyAnchor = RegExp(_familyPattern);
final _embeddedFamilyAnchor = RegExp('-$_familyPattern');
final _versionP = RegExp(r'(?<=\d)p(?=\d)');
final _claudeShorthand = RegExp(
  r'^(?:opus-[45]|(?:sonnet|haiku)-[3-5]|fable-5)(?=[.\-:]|$)',
);
final _kimiShorthand = RegExp(r'^(?:k2(?=[.-])|k3(?=[.\-:]|$))');
final _claudeVersion = RegExp(
  r'^claude-(?:(?:opus|sonnet|haiku|fable)-)?\d+(?:\.\d+)+',
);
final _glmVersion = RegExp(r'^glm-5-([1-3])(?=[-:]|$)');
final _unpricedSuffix = RegExp(
  r'-(?:nothinking|non-reasoning|thinking|reasoning|low|medium|high|xhigh|'
  r'minimal|fast|preview|latest|exp|ga|20\d{6}|20\d{2}-\d{2}-\d{2}|'
  r'\d{6}|\d{4})$',
);

String normalizeModelIdForPricing(String rawModelId) {
  var id = rawModelId.trim().toLowerCase();
  final colon = id.indexOf(':');
  if (colon > 0 &&
      !id.substring(0, colon).contains('/') &&
      !_routeTags.contains(id.substring(colon + 1).split(':').first.trim())) {
    id = id.substring(colon + 1).trim();
  }
  id = id.split('/').last.trim().replaceAll(RegExp(r'[\s_-]+'), '-');

  // Keep price-relevant route tags separate while cleaning the model name.
  final variants = id.indexOf(':');
  var route = variants == -1 ? '' : id.substring(variants);
  if (variants != -1) id = id.substring(0, variants);
  while (_removableRoute.hasMatch(route)) {
    route = route.replaceFirst(_removableRoute, '');
  }
  if (route.endsWith(':free')) route = ':free';

  while (true) {
    final relay = _relayPrefix.matchAsPrefix(id);
    if (relay != null) {
      id = id.substring(relay.end);
      continue;
    }
    // Strip a region only if it introduces a relay prefix or model family.
    final region = _regionalPrefix.matchAsPrefix(id);
    if (region != null &&
        (_relayPrefix.matchAsPrefix(id, region.end) != null ||
            _familyAnchor.matchAsPrefix(id, region.end) != null)) {
      id = id.substring(region.end);
      continue;
    }
    break;
  }

  id = id.replaceAll(_versionP, '.');
  // A family mentioned later in an already recognized ID is not a prefix.
  if (_familyAnchor.matchAsPrefix(id) == null &&
      !_claudeShorthand.hasMatch(id) &&
      !_kimiShorthand.hasMatch(id)) {
    final family = _embeddedFamilyAnchor.firstMatch(id);
    if (family != null) id = id.substring(family.start + 1);
  }
  if (_claudeShorthand.hasMatch(id)) id = 'claude-$id';
  if (_kimiShorthand.hasMatch(id)) id = 'kimi-$id';
  id = id.replaceFirstMapped(_claudeVersion, (m) => m[0]!.replaceAll('.', '-'));
  id = id.replaceFirstMapped(_glmVersion, (m) => 'glm-5.${m[1]}');
  while (_unpricedSuffix.hasMatch(id)) {
    id = id.replaceFirst(_unpricedSuffix, '');
  }
  return '$id$route';
}

const _freePricing = ModelPricing(
  inputPricePerMillion: 0,
  outputPricePerMillion: 0,
  cachedInputPricePerMillion: 0,
  cacheWritePricePerMillion: 0,
  isBuiltinReference: true,
);

const _tierWords = {
  'flash',
  'flashx',
  'lite',
  'mini',
  'nano',
  'air',
  'haiku',
  'pro',
  'max',
  'plus',
  'turbo',
  'ultraspeed',
  'highspeed',
  'contributor',
  'reasoner',
  'free',
  'luna',
  'terra',
  'sol',
  'astra',
};

ModelPricing? lookupBuiltinModelPricing(String modelId, {String? providerId}) {
  final id = normalizeModelIdForPricing(modelId);
  if (providerId != null) {
    final key = ModelPricingCatalog._providerKey(providerId, id);
    final channel = ModelPricingCatalog._providerPrices[key];
    if (channel != null) return channel;
  }
  if (id.endsWith(':free')) return _freePricing;
  final official = ModelPricingCatalog._lookupOfficial(modelId);
  return official ?? _lookupOfflinePricing(id);
}

ModelPricing? _lookupOfflinePricing(String id) {
  if (id.endsWith(':free')) return _freePricing;
  final tiers = id.split(RegExp(r'[-:]')).where(_tierWords.contains).toSet();
  _PriceRule? best;
  var longest = 0;
  for (final rule in _rules) {
    for (final prefix in rule.prefixes) {
      if (id.startsWith(prefix) && prefix.length > longest) {
        final suffix = id.substring(prefix.length);
        if (!prefix.endsWith('-') &&
            prefix != 'minimax-m' &&
            prefix != 'abab' &&
            suffix.isNotEmpty &&
            !RegExp(r'^[-.:@]').hasMatch(suffix)) {
          continue;
        }
        if (!tiers.every(prefix.split('-').contains)) continue;
        best = rule;
        longest = prefix.length;
      }
    }
  }
  if (best == null) return null;
  return ModelPricing(
    inputPricePerMillion: best.input,
    outputPricePerMillion: best.output,
    cachedInputPricePerMillion: best.cached,
    cacheWritePricePerMillion: best.write,
    currency: best.currency,
    isBuiltinReference: true,
  );
}

bool _validMultiplier(double? value) =>
    value != null && value.isFinite && value > 0;

bool _validPrice(double? value) =>
    value != null && value.isFinite && value >= 0;

bool hasManualModelPricing(ModelConfig? config) =>
    config?.inputPricePerMillion != null ||
    config?.outputPricePerMillion != null;

double effectivePricingMultiplier(
  ModelConfig? config,
  Map<String, dynamic>? providerCustomConfig,
) {
  final channel = double.tryParse(
    '${providerCustomConfig?['priceMultiplier']}',
  );
  final model = config?.priceMultiplier;
  return (_validMultiplier(channel) ? channel! : 1.0) *
      (_validMultiplier(model) ? model! : 1.0);
}

ModelPricing? resolveEffectiveModelPricing({
  required String providerId,
  required String rawModelId,
  ModelConfig? modelConfig,
  Map<String, dynamic>? providerCustomConfig,
}) {
  final config = modelConfig;
  final hasOverride = hasManualModelPricing(config);
  // Preserve the legacy currency fallback for hand-entered rates.
  final builtin = hasOverride
      ? _lookupOfflinePricing(normalizeModelIdForPricing(rawModelId))
      : lookupBuiltinModelPricing(rawModelId, providerId: providerId);
  final input = hasOverride
      ? (config?.inputPricePerMillion ?? 0.0)
      : builtin?.inputPricePerMillion;
  final output = hasOverride
      ? (config?.outputPricePerMillion ?? 0.0)
      : builtin?.outputPricePerMillion;
  if (input == null ||
      output == null ||
      !_validPrice(input) ||
      !_validPrice(output)) {
    return null;
  }
  final currency = config?.priceCurrency?.trim().toUpperCase();
  return ModelPricing(
    inputPricePerMillion: input,
    outputPricePerMillion: output,
    cachedInputPricePerMillion: hasOverride
        ? (_validPrice(config?.cachedInputPricePerMillion)
              ? config!.cachedInputPricePerMillion
              : input)
        : builtin?.cachedInputPricePerMillion,
    cacheWritePricePerMillion: hasOverride
        ? input * 1.25
        : builtin?.cacheWritePricePerMillion,
    currency: hasOverride && (currency == 'CNY' || currency == 'USD')
        ? currency!
        : (builtin?.currency ?? 'USD'),
    multiplier: effectivePricingMultiplier(config, providerCustomConfig),
    isBuiltinReference: !hasOverride && builtin != null,
  );
}

/// 返回原币种的百万分之一金额；输出已含思考 Token，不能重复收费。
int calculateCostMicros(TokenUsage usage, ModelPricing pricing) {
  final amount =
      usage.uncachedInputTokens * pricing.inputPricePerMillion +
      usage.cachedInputTokens *
          (pricing.cachedInputPricePerMillion ?? pricing.inputPricePerMillion) +
      usage.cacheWriteTokens *
          (pricing.cacheWritePricePerMillion ??
              pricing.inputPricePerMillion * 1.25) +
      usage.outputTokens * pricing.outputPricePerMillion;
  return (amount * pricing.multiplier).round();
}
