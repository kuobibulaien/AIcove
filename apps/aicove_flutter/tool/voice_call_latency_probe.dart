// Voice call latency probe: streaming LLM -> sentence split -> Fish Audio
// realtime WebSocket TTS, with per-stage timing.
//
// Usage (from apps/aicove_flutter):
//   tool/flutterw --dart run tool/voice_call_latency_probe.dart [options]
//
// Options:
//   --text <s>        Simulated user utterance (ASR final result).
//   --runs <n>        Number of rounds (default 3).
//   --latency <m>     Fish latency mode: balanced | normal (default balanced).
//   --voice <id>      Fish reference_id (default: first Fish voice preset).
//   --model <id>      Chat model (default deepseek-flash).
//   --min-chars <n>   Minimum chars before a comma-level cut (default 6).
//   --baseline        Also run the naive path: full LLM text, then one-shot
//                     HTTP TTS, measuring time until the full audio arrives.
//   --out <dir>       Write each round's audio as WAV into this directory.
//   --play            Play the last round's WAV with afplay.
//   --keepalive <gaps> Keep one TTS session for a whole call. <gaps> is a
//                     comma list of idle seconds before each turn, e.g.
//                     0,10,30,60. Reports per-turn latency and whether the
//                     server closed the session while idle.
//   --ping <s>        WebSocket ping interval in keepalive mode (0 = off).
//   --asr <wav>       Stream a 16 kHz mono WAV in real time to Aliyun
//                     Paraformer realtime ASR (as if from the mic), then
//                     feed the final transcript into the normal round.
//                     T0 becomes the end of speech inside the WAV.
//   --silence <ms>    ASR end-of-sentence silence (default 500).
//   --interrupt <n>   In keepalive mode, simulate barge-in on turn n: stop
//                     sending text once its first audio arrives, and report
//                     how much already-queued audio still arrives.
//
// Credentials are read from the macOS AIcove app preferences
// (FISH_API_KEY / DEEPSEEK_API_KEY environment variables take precedence).
// Keys are never printed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/data/msgpack.dart';

const _prefsPath =
    'Library/Containers/com.example.aicoveFlutter/Data/Library/Preferences/'
    'com.example.aicoveFlutter.plist';
const _fishWsUrl = 'wss://api.fish.audio/v1/tts/live';
const _fishHttpUrl = 'https://api.fish.audio/v1/tts';
const _deepseekUrl = 'https://api.deepseek.com/chat/completions';
const _aliyunAsrUrl = 'wss://dashscope.aliyuncs.com/api-ws/v1/inference';
const _sampleRate = 24000;
const _bytesPerSecond = _sampleRate * 2; // 16-bit mono PCM

const _systemPrompt =
    '你正在和用户打语音电话，你是用户的好朋友。'
    '要求：像真人打电话一样说话，口语化，短句；'
    '开头先用一两个字给出自然的即时反应（比如“诶？”“嗯……”“哈哈”），再展开；'
    '整轮回复控制在三到五句；不要使用 Markdown、列表、表情符号或任何标签。';

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);
  final creds = await _Credentials.load(args.voice);
  stdout.writeln(
    'model=${args.model} fishModel=${creds.fishModel} '
    'voice=${creds.voiceId} latency=${args.latency} '
    'minChars=${args.minChars}',
  );

  final client = HttpClient();
  if (args.keepaliveGaps != null) {
    try {
      await _runKeepalive(client, creds, args);
    } finally {
      client.close(force: true);
    }
    return;
  }
  final results = <_RoundResult>[];
  try {
    for (var i = 1; i <= args.runs; i++) {
      stdout.writeln('\n=== round $i/${args.runs} ===');
      _AsrResult? asr;
      if (args.asrWav != null) {
        asr = await _runAsr(creds, args);
        asr.printReport();
        args.text = asr.text;
      }
      final r = await _runStreamingRound(client, creds, args);
      r.asrEndpointMs = asr?.endpointMs;
      results.add(r);
      r.printReport();
      if (args.outDir != null) {
        final file = File('${args.outDir}/round_$i.wav');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(_wav(r.pcm));
        stdout.writeln('wav: ${file.path}');
      }
      if (args.baseline) {
        final b = await _runBaselineRound(client, creds, args);
        stdout.writeln(
          'baseline (full text then one-shot TTS): '
          'llmDone=${b.$1}ms fullAudio=${b.$2}ms',
        );
      }
    }
  } finally {
    client.close(force: true);
  }

  if (results.length > 1) {
    stdout.writeln('\n=== summary (ms from end of user speech) ===');
    _summary('ws connect+start (pre-call)', results.map((r) => r.wsReady));
    _summary('llm first token', results.map((r) => r.llmFirstToken));
    _summary('first segment sent', results.map((r) => r.firstSegmentSent));
    _summary('first audio chunk', results.map((r) => r.firstAudio));
    if (args.asrWav != null) {
      _summary(
        'asr endpoint (speech end->final)',
        results.map((r) => r.asrEndpointMs),
      );
      _summary(
        'speech end -> first audio',
        results.map(
          (r) => r.firstAudio == null || r.asrEndpointMs == null
              ? null
              : r.firstAudio! + r.asrEndpointMs!,
        ),
      );
    }
    _summary('llm done', results.map((r) => r.llmDone));
    _summary('stall total', results.map((r) => r.stallMs));
  }

  if (args.play && args.outDir != null) {
    await Process.run('afplay', ['${args.outDir}/round_${args.runs}.wav']);
  }
}

Future<_RoundResult> _runStreamingRound(
  HttpClient client,
  _Credentials creds,
  _Args args,
) async {
  // Pre-call: connect and start the TTS session before the user finishes.
  final preWatch = Stopwatch()..start();
  final ws = await WebSocket.connect(
    _fishWsUrl,
    headers: {
      'Authorization': 'Bearer ${creds.fishKey}',
      'model': creds.fishModel,
    },
  );
  ws.add(
    Msgpack.encode({
      'event': 'start',
      'request': {
        'text': '',
        'reference_id': creds.voiceId,
        'format': 'pcm',
        'sample_rate': _sampleRate,
        'latency': args.latency,
      },
    }),
  );
  final wsReady = preWatch.elapsedMilliseconds;

  // T0: user finished speaking (ASR final result available).
  final clock = Stopwatch()..start();
  final result = _RoundResult(wsReady: wsReady);
  final pcm = BytesBuilder(copy: false);
  final finished = Completer<void>();
  ws.listen(
    (data) {
      if (data is! List<int>) return;
      final msg = Msgpack.decode(Uint8List.fromList(data));
      if (msg is! Map) return;
      final event = msg['event'];
      if (event == 'audio') {
        final audio = msg['audio'];
        if (audio is Uint8List && audio.isNotEmpty) {
          result.audioChunks.add((clock.elapsedMilliseconds, audio.length));
          pcm.add(audio);
        }
      } else if (event == 'finish') {
        if (msg['reason'] != 'stop') result.errors.add('finish: $msg');
        if (!finished.isCompleted) finished.complete();
      } else if (event == 'log' || event == 'error') {
        result.errors.add('$msg');
      }
    },
    onError: (Object e) {
      result.errors.add('ws error: $e');
      if (!finished.isCompleted) finished.complete();
    },
    onDone: () {
      if (!finished.isCompleted) finished.complete();
    },
  );

  final splitter = _Splitter(args.minChars);
  void sendSegment(String segment) {
    if (segment.trim().isEmpty) return;
    result.segments.add((clock.elapsedMilliseconds, segment));
    ws.add(Msgpack.encode({'event': 'text', 'text': segment}));
    ws.add(Msgpack.encode({'event': 'flush'}));
  }

  await _streamChat(
    client,
    creds,
    args,
    onDelta: (delta) {
      result.llmFirstToken ??= clock.elapsedMilliseconds;
      result.fullText.write(delta);
      splitter.push(delta).forEach(sendSegment);
    },
  );
  result.llmDone = clock.elapsedMilliseconds;
  sendSegment(splitter.drain());
  ws.add(Msgpack.encode({'event': 'stop'}));

  await finished.future.timeout(
    const Duration(seconds: 60),
    onTimeout: () {
      result.errors.add('timeout waiting for finish');
    },
  );
  await ws.close();
  result.pcm = pcm.takeBytes();
  return result;
}

class _AsrResult {
  String text = '';
  int speechEndMs = 0;
  int? firstPartialMs;
  int? finalMs;
  final partials = <(int, String)>[];
  final errors = <String>[];

  /// Time from the end of speech to the final sentence result.
  int? get endpointMs => finalMs == null ? null : finalMs! - speechEndMs;

  void printReport() {
    stdout.writeln('asr: "$text"');
    stdout.writeln(
      'asr speech ends @${speechEndMs}ms, first partial '
      '@${firstPartialMs}ms, final @${finalMs}ms -> endpoint '
      '${endpointMs}ms, partial updates: ${partials.length}',
    );
    for (final e in errors) {
      stdout.writeln('  ! $e');
    }
  }
}

/// Streams a WAV to Aliyun Paraformer realtime ASR at real-time pace, then
/// keeps sending silence like a live mic until the sentence ends.
Future<_AsrResult> _runAsr(_Credentials creds, _Args args) async {
  final key = creds.aliyunKey;
  if (key == null) throw StateError('Missing Aliyun key for ASR.');
  final wav = File(args.asrWav!).readAsBytesSync();
  final pcm = Uint8List.sublistView(wav, _wavDataOffset(wav));
  final samples = ByteData.sublistView(pcm);
  // Speech end = last 10 ms frame whose peak exceeds the threshold.
  var lastLoud = 0;
  for (var i = 0; i + 1 < pcm.length; i += 2) {
    if (samples.getInt16(i, Endian.little).abs() > 800) lastLoud = i;
  }
  final result = _AsrResult()..speechEndMs = lastLoud * 1000 ~/ 32000;

  final ws = await WebSocket.connect(
    _aliyunAsrUrl,
    headers: {'Authorization': 'Bearer $key'},
  );
  final random = Random();
  final taskId = List.generate(
    32,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  final started = Completer<void>();
  final finished = Completer<void>();
  final clock = Stopwatch();
  ws.listen(
    (data) {
      if (data is! String) return;
      final msg = jsonDecode(data) as Map<String, dynamic>;
      final event = (msg['header'] as Map)['event'];
      if (event == 'task-started') {
        started.complete();
      } else if (event == 'result-generated') {
        final sentence =
            ((msg['payload'] as Map)['output'] as Map)['sentence'] as Map?;
        if (sentence == null) return;
        final text = sentence['text']?.toString() ?? '';
        final at = clock.elapsedMilliseconds;
        result.firstPartialMs ??= at;
        result.partials.add((at, text));
        if (sentence['sentence_end'] == true && result.finalMs == null) {
          result.finalMs = at;
          result.text = text;
        }
      } else if (event == 'task-finished' || event == 'task-failed') {
        if (event == 'task-failed') result.errors.add(data);
        if (!started.isCompleted) started.complete();
        if (!finished.isCompleted) finished.complete();
      }
    },
    onDone: () {
      if (!started.isCompleted) started.complete();
      if (!finished.isCompleted) finished.complete();
    },
  );
  ws.add(
    jsonEncode({
      'header': {
        'action': 'run-task',
        'task_id': taskId,
        'streaming': 'duplex',
      },
      'payload': {
        'task_group': 'audio',
        'task': 'asr',
        'function': 'recognition',
        'model': args.asrModel,
        'parameters': {
          'format': 'pcm',
          'sample_rate': 16000,
          'max_sentence_silence': args.silenceMs,
        },
        'input': {},
      },
    }),
  );
  await started.future.timeout(const Duration(seconds: 10));

  // 100 ms frames at real-time pace; after the file, send silence (max 5 s).
  const frame = 3200;
  final silence = Uint8List(frame);
  clock.start();
  var sentMs = 0;
  for (var off = 0; ; off += frame) {
    if (finished.isCompleted || result.finalMs != null) break;
    if (off >= pcm.length && sentMs > result.speechEndMs + 5000) break;
    ws.add(
      off < pcm.length
          ? Uint8List.sublistView(pcm, off, (off + frame).clamp(0, pcm.length))
          : silence,
    );
    sentMs += 100;
    final wait = sentMs - clock.elapsedMilliseconds;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
  }
  ws.add(
    jsonEncode({
      'header': {
        'action': 'finish-task',
        'task_id': taskId,
        'streaming': 'duplex',
      },
      'payload': {'input': {}},
    }),
  );
  await finished.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  await ws.close();
  if (result.text.isEmpty && result.partials.isNotEmpty) {
    result.text = result.partials.last.$2;
  }
  return result;
}

/// Byte offset of the PCM payload (skips any extra RIFF chunks).
int _wavDataOffset(Uint8List wav) {
  final d = ByteData.sublistView(wav);
  var pos = 12;
  while (pos + 8 <= wav.length) {
    final id = String.fromCharCodes(wav.sublist(pos, pos + 4));
    final size = d.getUint32(pos + 4, Endian.little);
    if (id == 'data') return pos + 8;
    pos += 8 + size + (size & 1);
  }
  throw const FormatException('WAV data chunk not found');
}

/// One TTS session across several turns separated by idle gaps.
Future<void> _runKeepalive(
  HttpClient client,
  _Credentials creds,
  _Args args,
) async {
  final callClock = Stopwatch()..start();
  String t() => (callClock.elapsedMilliseconds / 1000).toStringAsFixed(1);
  final ws = await WebSocket.connect(
    _fishWsUrl,
    headers: {
      'Authorization': 'Bearer ${creds.fishKey}',
      'model': creds.fishModel,
    },
  );
  if (args.pingSeconds > 0) {
    ws.pingInterval = Duration(seconds: args.pingSeconds);
  }
  ws.add(
    Msgpack.encode({
      'event': 'start',
      'request': {
        'text': '',
        'reference_id': creds.voiceId,
        'format': 'pcm',
        'sample_rate': _sampleRate,
        'latency': args.latency,
      },
    }),
  );
  stdout.writeln('[${t()}s] session started, ping=${args.pingSeconds}s');

  Stopwatch? turnClock;
  final turnChunks = <(int, int)>[];
  var closed = false;
  ws.listen(
    (data) {
      if (data is! List<int>) return;
      final msg = Msgpack.decode(Uint8List.fromList(data));
      if (msg is! Map) return;
      if (msg['event'] == 'audio') {
        final audio = msg['audio'];
        if (audio is Uint8List && audio.isNotEmpty) {
          turnChunks.add((turnClock?.elapsedMilliseconds ?? -1, audio.length));
        }
      } else {
        stdout.writeln('[${t()}s] event: $msg');
      }
    },
    onError: (Object e) => stdout.writeln('[${t()}s] ws error: $e'),
    onDone: () {
      closed = true;
      stdout.writeln(
        '[${t()}s] session closed by server: '
        'code=${ws.closeCode} reason=${ws.closeReason}',
      );
    },
  );

  final gaps = args.keepaliveGaps!;
  for (var i = 0; i < gaps.length; i++) {
    final turn = i + 1;
    if (gaps[i] > 0) {
      stdout.writeln('[${t()}s] idle ${gaps[i]}s ...');
      await Future<void>.delayed(Duration(seconds: gaps[i]));
    }
    if (closed) {
      stdout.writeln('turn $turn: SKIPPED, session already closed');
      break;
    }
    turnChunks.clear();
    turnClock = Stopwatch()..start();
    final interrupt = args.interruptTurn == turn;
    int? interruptedAt;
    final splitter = _Splitter(args.minChars);
    void send(String segment) {
      if (segment.trim().isEmpty || closed) return;
      if (interrupt && turnChunks.isNotEmpty) {
        interruptedAt ??= turnClock!.elapsedMilliseconds;
        return;
      }
      ws.add(Msgpack.encode({'event': 'text', 'text': segment}));
      ws.add(Msgpack.encode({'event': 'flush'}));
    }

    int? firstToken;
    await _streamChat(
      client,
      creds,
      args,
      onDelta: (delta) {
        firstToken ??= turnClock!.elapsedMilliseconds;
        splitter.push(delta).forEach(send);
      },
    );
    send(splitter.drain());
    // Turn ends once audio has been quiet for 2s.
    var lastCount = -1;
    while (!closed) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (turnChunks.length == lastCount) break;
      lastCount = turnChunks.length;
    }
    final first = turnChunks.isEmpty ? null : turnChunks.first.$1;
    final audioMs =
        (turnChunks.fold<int>(0, (a, c) => a + c.$2) * 1000 / _bytesPerSecond)
            .round();
    stdout.writeln(
      'turn $turn (after ${gaps[i]}s idle): '
      'llmFirst=${firstToken}ms firstAudio=${first}ms '
      'chunks=${turnChunks.length} audio=${audioMs}ms',
    );
    if (interrupt) {
      final at = interruptedAt ?? first;
      final stale = at == null
          ? 0
          : turnChunks.where((c) => c.$1 > at).fold<int>(0, (a, c) => a + c.$2);
      final lastStale = turnChunks.isEmpty ? null : turnChunks.last.$1;
      stdout.writeln(
        '  interrupt at ${at}ms: audio still arriving after it '
        '${(stale * 1000 / _bytesPerSecond).round()}ms, '
        'last chunk at ${lastStale}ms',
      );
    }
  }
  if (!closed) {
    ws.add(Msgpack.encode({'event': 'stop'}));
    await ws.close();
  }
  stdout.writeln('[${t()}s] done');
}

/// Naive path: wait for the whole reply, then one HTTP TTS request.
Future<(int, int)> _runBaselineRound(
  HttpClient client,
  _Credentials creds,
  _Args args,
) async {
  final clock = Stopwatch()..start();
  final text = StringBuffer();
  await _streamChat(client, creds, args, onDelta: text.write);
  final llmDone = clock.elapsedMilliseconds;
  final req = await client.postUrl(Uri.parse(_fishHttpUrl));
  req.headers
    ..set('Authorization', 'Bearer ${creds.fishKey}')
    ..set('model', creds.fishModel)
    ..contentType = ContentType.json;
  req.write(
    jsonEncode({
      'text': text.toString(),
      'reference_id': creds.voiceId,
      'format': 'mp3',
    }),
  );
  final res = await req.close();
  await res.drain<void>();
  if (res.statusCode != 200) {
    stdout.writeln('baseline TTS http ${res.statusCode}');
  }
  return (llmDone, clock.elapsedMilliseconds);
}

Future<void> _streamChat(
  HttpClient client,
  _Credentials creds,
  _Args args, {
  required void Function(String delta) onDelta,
}) async {
  final req = await client.postUrl(Uri.parse(_deepseekUrl));
  req.headers
    ..set('Authorization', 'Bearer ${creds.deepseekKey}')
    ..contentType = ContentType.json;
  req.write(
    jsonEncode({
      'model': args.model,
      'stream': true,
      'thinking': {'type': 'disabled'},
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {'role': 'user', 'content': args.text},
      ],
    }),
  );
  final res = await req.close();
  if (res.statusCode != 200) {
    final body = await utf8.decodeStream(res);
    throw HttpException('chat http ${res.statusCode}: $body');
  }
  await for (final line
      in res.transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('data:')) continue;
    final payload = line.substring(5).trim();
    if (payload == '[DONE]') break;
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) continue;
    final delta = (choices.first as Map)['delta'] as Map?;
    final content = delta?['content'];
    if (content is String && content.isNotEmpty) onDelta(content);
  }
}

/// Cuts streaming text into speakable segments. Strong punctuation always
/// cuts; weak punctuation cuts once the buffer has [minChars] characters.
class _Splitter {
  _Splitter(this.minChars);

  final int minChars;
  final _buf = StringBuffer();
  static final _strong = RegExp(r'[。！？!?…~～\n]');
  static final _weak = RegExp(r'[，,、；;：:]');

  List<String> push(String delta) {
    final out = <String>[];
    for (final rune in delta.runes) {
      final ch = String.fromCharCode(rune);
      _buf.write(ch);
      final strong = _strong.hasMatch(ch);
      final weak = _weak.hasMatch(ch);
      if ((strong && _buf.toString().trim().length > 1) ||
          (weak && _buf.length >= minChars)) {
        out.add(_buf.toString());
        _buf.clear();
      }
    }
    return out;
  }

  String drain() {
    final rest = _buf.toString();
    _buf.clear();
    return rest;
  }
}

class _RoundResult {
  _RoundResult({required this.wsReady});

  final int wsReady;
  int? asrEndpointMs;
  int? llmFirstToken;
  int llmDone = 0;
  final fullText = StringBuffer();
  final segments = <(int, String)>[];
  final audioChunks = <(int, int)>[];
  final errors = <String>[];
  Uint8List pcm = Uint8List(0);

  int? get firstSegmentSent => segments.isEmpty ? null : segments.first.$1;
  int? get firstAudio => audioChunks.isEmpty ? null : audioChunks.first.$1;

  /// Simulates a player that starts at the first chunk and plays back to
  /// back; returns total silence caused by chunks arriving too late.
  int get stallMs {
    if (audioChunks.isEmpty) return 0;
    var playhead = audioChunks.first.$1.toDouble();
    var stall = 0.0;
    for (final (at, bytes) in audioChunks) {
      if (at > playhead) {
        stall += at - playhead;
        playhead = at.toDouble();
      }
      playhead += bytes * 1000 / _bytesPerSecond;
    }
    return stall.round();
  }

  void printReport() {
    stdout.writeln('reply: ${fullText.toString().replaceAll('\n', ' ')}');
    stdout.writeln('ws connect+start (before T0): ${wsReady}ms');
    stdout.writeln('llm first token: ${llmFirstToken}ms, done: ${llmDone}ms');
    for (final (at, s) in segments) {
      stdout.writeln('  seg @${at}ms  "${s.replaceAll('\n', ' ')}"');
    }
    final audioMs = (pcm.length * 1000 / _bytesPerSecond).round();
    final last = audioChunks.isEmpty ? null : audioChunks.last.$1;
    stdout.writeln(
      'first audio: ${firstAudio}ms, last chunk: ${last}ms, '
      'chunks: ${audioChunks.length}, audio length: ${audioMs}ms, '
      'stall: ${stallMs}ms',
    );
    for (final e in errors) {
      stdout.writeln('  ! $e');
    }
  }
}

void _summary(String label, Iterable<int?> values) {
  final v = values.whereType<int>().toList()..sort();
  if (v.isEmpty) return;
  final avg = (v.reduce((a, b) => a + b) / v.length).round();
  stdout.writeln(
    '${label.padRight(30)} min ${v.first}  avg $avg  max ${v.last}',
  );
}

Uint8List _wav(Uint8List pcm) {
  final header = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, _sampleRate, Endian.little);
  header.setUint32(28, _bytesPerSecond, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}

class _Credentials {
  _Credentials(
    this.fishKey,
    this.deepseekKey,
    this.fishModel,
    this.voiceId,
    this.aliyunKey,
  );

  final String fishKey;
  final String deepseekKey;
  final String fishModel;
  final String voiceId;
  final String? aliyunKey;

  static Future<_Credentials> load(String? voiceOverride) async {
    final plist = '${Platform.environment['HOME']}/$_prefsPath';
    final prefs = await _plistPrefs(plist);
    Map? pref(String key) =>
        prefs[key] is String ? jsonDecode(prefs[key] as String) as Map? : null;
    final models = pref('flutter.aicove.ui_models.v1');
    final tts = pref('flutter.aicove.plugins.tts.config');
    Map? provider(String id) => (models?['providers'] as List?)
        ?.whereType<Map>()
        .firstWhere((p) => p['id'] == id, orElse: () => {});
    String? key(Map? p) {
      final keys = p?['apiKeys'];
      return keys is List && keys.isNotEmpty ? keys.first.toString() : null;
    }

    final fish = provider('fish_audio');
    final fishKey = Platform.environment['FISH_API_KEY'] ?? key(fish);
    final deepseekKey =
        Platform.environment['DEEPSEEK_API_KEY'] ?? key(provider('deepseek'));
    Map? binding;
    for (final preset in (tts?['voicePresets'] as List? ?? const [])) {
      for (final b in ((preset as Map)['bindings'] as List? ?? const [])) {
        if (b is Map && b['providerId'] == 'fish_audio') {
          binding ??= b;
        }
      }
    }
    if (fishKey == null || deepseekKey == null) {
      throw StateError('Missing Fish Audio or DeepSeek key.');
    }
    final voiceId = voiceOverride ?? binding?['remoteVoiceId']?.toString();
    if (voiceId == null) throw StateError('No Fish voice preset found.');
    final fishModel =
        binding?['modelId']?.toString() ??
        (fish?['visible_models'] as List?)?.first.toString() ??
        's2.1-pro';
    final aliyunKey =
        Platform.environment['DASHSCOPE_API_KEY'] ?? key(provider('aliyun'));
    return _Credentials(fishKey, deepseekKey, fishModel, voiceId, aliyunKey);
  }

  static Future<Map> _plistPrefs(String plist) async {
    if (!File(plist).existsSync()) return const {};
    final r = await Process.run('plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      plist,
    ]);
    if (r.exitCode != 0) return const {};
    return jsonDecode(r.stdout as String) as Map;
  }
}

class _Args {
  String text = '我今天下午去面试了，好紧张啊，面试官问了好多我没准备的问题。';
  int runs = 3;
  String latency = 'balanced';
  String? voice;
  String model = 'deepseek-flash';
  int minChars = 6;
  bool baseline = false;
  String? outDir;
  bool play = false;
  List<int>? keepaliveGaps;
  int pingSeconds = 0;
  int? interruptTurn;
  String? asrWav;
  String asrModel = 'paraformer-realtime-v2';
  int silenceMs = 500;

  static _Args parse(List<String> argv) {
    final a = _Args();
    for (var i = 0; i < argv.length; i++) {
      String next() => argv[++i];
      switch (argv[i]) {
        case '--text':
          a.text = next();
        case '--runs':
          a.runs = int.parse(next());
        case '--latency':
          a.latency = next();
        case '--voice':
          a.voice = next();
        case '--model':
          a.model = next();
        case '--min-chars':
          a.minChars = int.parse(next());
        case '--baseline':
          a.baseline = true;
        case '--out':
          a.outDir = next();
        case '--play':
          a.play = true;
        case '--keepalive':
          a.keepaliveGaps = next().split(',').map(int.parse).toList();
        case '--ping':
          a.pingSeconds = int.parse(next());
        case '--asr':
          a.asrWav = next();
        case '--asr-model':
          a.asrModel = next();
        case '--silence':
          a.silenceMs = int.parse(next());
        case '--interrupt':
          a.interruptTurn = int.parse(next());
        default:
          throw ArgumentError('Unknown option ${argv[i]}');
      }
    }
    return a;
  }
}
