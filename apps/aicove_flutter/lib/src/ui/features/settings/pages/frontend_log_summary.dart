import '../../../../core/app_logger.dart';

String frontendLogTitle(LogEntry log) {
  final meta = log.metadata ?? const <String, dynamic>{};
  final state = meta['state'] is Map ? meta['state'] as Map : const {};
  final elapsed = meta['elapsedMs'];
  final time = elapsed is num ? '${elapsed}ms' : '未知';
  switch (meta['event']) {
    case 'animationDecision':
      final action = state['animate'] == false
          ? '跳过入场动画'
          : state['animate'] == true
              ? '播放入场动画'
              : '入场动画检查';
      return state['viewportClock'] == true ? '$action · 视口创建后 $time' : action;
    case 'historyColdLoad':
      if (meta['phase'] == 'start') return '开始加载历史';
      if (meta['phase'] == 'end') return '历史加载完成 · 用时 $time';
      return '历史加载记录 · 累计 $time';
    case 'pageLayoutReady':
    case 'historyReady':
      return '${log.message} · 进入后 $time';
    case 'pageLeft':
      return '离开聊天 · 停留 $time';
    case 'pageLeftBeforeLayout':
      return '离开时尚未完成布局 · 已等待 $time';
    default:
      return elapsed is num ? '${log.message} · 累计 $time' : log.message;
  }
}

String frontendLogSummary(LogEntry log) {
  final meta = log.metadata ?? const <String, dynamic>{};
  final state = meta['state'] is Map ? meta['state'] as Map : const {};
  if (meta['event'] == 'animationDecision') {
    return '${state['animate'] == false ? '本次不播放入场动画。' : '本条记录的是是否播放动画的决定。'}'
        '\n${state['viewportClock'] == true ? '时间从本次视口创建开始计算。' : '旧记录沿用消息操作的累计计时。'}'
        '不是动画执行时长，也不是帧耗时。';
  }
  if (meta['event'] != 'historyColdLoad' || meta['phase'] != 'end') {
    return '“累计／进入后／停留”表示距相应操作开始的时间，不是单阶段或单帧耗时。';
  }
  String metric(String key, String unit) =>
      state[key] is num ? '${state[key]}$unit' : '未采集';
  const fields = {
    'payloadReplyChars': '原始回复',
    'payloadProcessedChars': '处理后正文',
    'payloadThoughtChars': '思考内容',
    'payloadPluginEventChars': '插件事件',
    'payloadPluginContentChars': '插件内容',
    'payloadAudioResultChars': '音频结果',
    'payloadToolArgsChars': '工具调用',
    'payloadToolResultChars': '原始工具结果',
    'payloadProjectionChars': '显示快照',
    'payloadSupplementChars': '补充内容',
    'payloadOtherChars': '其他字段',
  };
  final counts = fields.entries
      .where(
          (entry) => state[entry.key] is num && (state[entry.key] as num) > 0)
      .toList()
    ..sort((a, b) => (state[b.key] as num).compareTo(state[a.key] as num));
  return [
    '读取 ${metric('rawCount', '条')}原始消息，生成 ${metric('projectedCount', '项')}显示内容。',
    '读取载荷：${metric('rawPayloadChars', '字符')}；最大单条：${metric('maxRawPayloadChars', '字符')}。',
    if (state['displayRead'] == true) '本次按显示快照读取，字段体积是实际取回的数据，不是数据库原始记录总量。',
    if (state.containsKey('backgroundDecode'))
      '${state['backgroundDecode'] == true ? '后台解析' : '小载荷直接解析'}；任务往返 ${metric('workerMs', 'ms')}；快照回退 ${metric('displayFallbackCount', '条')}。',
    '读取阶段 ${metric('rawReadMs', 'ms')}；内容块读取 ${metric('blockReadMs', 'ms')}；'
        '解析 ${metric('decodeMs', 'ms')}；显示转换 ${metric('projectionMs', 'ms')}。',
    '安装内存快照 ${metric('installMs', 'ms')}；统计自身 ${metric('payloadStatsMs', 'ms')}；'
        '排队 ${metric('queueMs', 'ms')}（不含在加载总时长内）。',
    if (!state.containsKey('payloadScanTruncated')) '此旧记录未采集字段体积。',
    if (state.containsKey('payloadScanTruncated')) ...[
      '字段体积仅统计字符串值，不含键名和 JSON 标点；不是文件字节或内存占用。',
      if (state['payloadScanTruncated'] == true) '统计已截断，以下为已扫描部分，不能当成完整占比。',
      for (final entry in counts) '${entry.value}：${metric(entry.key, '字符')}',
    ],
    '读取阶段包含数据库等待和数据传递，不等于纯 SQL 执行时间；以上也不是帧耗时。',
  ].join('\n');
}
