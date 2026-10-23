import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aicove_quickjs/aicove_quickjs.dart';

import '../../../core/network/public_network.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../data/workspace_store.dart';
import '../domain/workspace_models.dart';
import 'workspace_image.dart';

/// Bounded tail used by text()/console and by the host-owned output artifact.
class WorkspaceScriptOutput {
  static int _artifactSequence = 0;
  static String artifactPath(String runId) {
    final id = runId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '.aicove/outputs/${id.substring(0, id.length.clamp(0, 70))}-${++_artifactSequence}.txt';
  }

  static const maxFileBytes = 8 * 1024 * 1024;
  static const maxModelBytes = 50 * 1024;
  static const maxModelLines = 2000;
  final _chunks = Queue<Uint8List>();
  int _length = 0;
  bool fileTruncated = false;
  void add(String value) => addChunk('$value\n');

  void addChunk(String value) {
    var bytes = Uint8List.fromList(utf8.encode(value));
    if (bytes.length >= maxFileBytes) {
      fileTruncated |= _length + bytes.length > maxFileBytes;
      _chunks.clear();
      _length = 0;
      bytes = Uint8List.sublistView(bytes, bytes.length - maxFileBytes);
    }
    _chunks.add(bytes);
    _length += bytes.length;
    while (_length > maxFileBytes) {
      fileTruncated = true;
      final first = _chunks.removeFirst();
      final remove = (_length - maxFileBytes).clamp(0, first.length);
      _length -= remove;
      if (remove < first.length) {
        _chunks.addFirst(Uint8List.sublistView(first, remove));
      }
    }
  }

  Uint8List get fileBytes {
    final builder = BytesBuilder(copy: false);
    for (final chunk in _chunks) {
      builder.add(chunk);
    }
    return _validTail(builder.takeBytes());
  }

  String get modelText => modelTail(utf8.decode(fileBytes));

  static String modelTail(String text) {
    if (text.isEmpty) return '';
    final lines = text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final selected = lines
        .skip((lines.length - maxModelLines).clamp(0, lines.length))
        .join('\n');
    final bytes = Uint8List.fromList(
      utf8.encode('$selected${text.endsWith('\n') ? '\n' : ''}'),
    );
    return utf8.decode(
      _validTail(
        bytes.length <= maxModelBytes
            ? bytes
            : Uint8List.sublistView(bytes, bytes.length - maxModelBytes),
      ),
    );
  }

  bool get truncated => fileTruncated || modelText != utf8.decode(fileBytes);
  static Uint8List _validTail(Uint8List bytes) {
    var start = 0;
    while (start < bytes.length && (bytes[start] & 0xc0) == 0x80) {
      start++;
    }
    return start == 0 ? bytes : Uint8List.sublistView(bytes, start);
  }
}

class WorkspaceScript {
  WorkspaceScript({
    required this.store,
    required this.workspace,
    required this.runId,
    this.tools,
    this.isCancelled,
    PublicNetwork Function()? networkFactory,
    this.resources = const {},
    this.discoveryOnly = false,
  }) : _networkFactory = networkFactory ?? PublicNetwork.new;

  /// Extension invocations reuse the workspace host without granting a workspace.
  WorkspaceScript.extension({
    required this.runId,
    this.tools,
    this.isCancelled,
    this.resources = const {},
    this.discoveryOnly = false,
    PublicNetwork Function()? networkFactory,
  }) : store = null,
       workspace = 'extension',
       _networkFactory = networkFactory ?? PublicNetwork.new;

  final Map<String, List<int>> resources;
  final bool discoveryOnly;
  static const maxChunkBytes = 4 * 1024 * 1024;
  final WorkspaceStore? store;
  final String workspace, runId;
  final ScriptToolAccess? tools;
  final bool Function()? isCancelled;
  final PublicNetwork Function() _networkFactory;
  final output = WorkspaceScriptOutput();
  final images = <ToolImage>[];

  /// Normalization collisions remove every competing tool, not just the last.
  static Map<String, List<AITool>> _toolGroups(Iterable<AITool> tools) {
    final groups = <String, List<AITool>>{};
    for (final tool in tools) {
      if (tool.name == 'codemode') continue;
      var name = tool.name.replaceAll(RegExp(r'[^a-zA-Z0-9_$]'), '_');
      if (name.isEmpty || RegExp(r'^[0-9]').hasMatch(name)) name = '_$name';
      groups.putIfAbsent(name, () => []).add(tool);
    }
    return groups;
  }

  static Map<String, AITool> exportedTools(Iterable<AITool> tools) => {
    for (final entry in _toolGroups(tools).entries)
      if (entry.value.length == 1 && !['list', 'describe'].contains(entry.key))
        entry.key: entry.value.single,
  };

  static List<Map<String, dynamic>> toolDescriptions(
    Iterable<AITool> tools,
  ) => [
    for (final entry in _toolGroups(tools).entries)
      if (entry.value.length == 1 && !['list', 'describe'].contains(entry.key))
        {
          'exportName': entry.key,
          'available': true,
          ...Map<String, dynamic>.from(
            entry.value.single.toOpenAISchema()['function'] as Map,
          ),
        }
      else
        {
          'exportName': entry.key,
          'available': false,
          'names': entry.value.map((t) => t.name).toList(),
          'reason': entry.value.length > 1
              ? 'Normalized tool name collision; none exported'
              : 'Reserved host method name',
        },
  ];

  Future<ToolOutput> run(
    String code, {
    Object? args,
    Duration timeout = const Duration(seconds: 30),
    void Function(String)? captureReturn,
  }) async {
    final network = _networkFactory();
    final exports = exportedTools(tools?.tools ?? const []);
    final descriptions = toolDescriptions(tools?.tools ?? const []);
    final session = QuickJsAsyncSession();
    String? error;
    try {
      final result = await session.run(
        '''
const args = ${jsonEncode(args)};
const __toolInfo = ${jsonEncode(descriptions)};
$_workspaceBootstrap
$code
''',
        timeout: timeout,
        isCancelled: isCancelled,
        onStop: network.close,
        onText: output.add,
        hostCall: (method, values, active) => WorkspaceStore.guardCommits(
          active,
          () async {
            void check() {
              if (!active() || (isCancelled?.call() ?? false)) {
                throw StateError('Script invocation closed');
              }
            }

            check();
            if (discoveryOnly) {
              throw StateError(
                'Host calls unavailable during plugin registration',
              );
            }
            switch (method) {
              case 'resourceList':
                return resources.keys.toList()..sort();
              case 'resourceRead':
                final path = values[0] as String;
                final bytes = resources[path];
                if (bytes == null) {
                  throw StateError('Resource unavailable: $path');
                }
                final offset = _integer(values[1]),
                    length = _integer(values[2]);
                if (offset < 0 || length < 0 || length > maxChunkBytes) {
                  throw ArgumentError('Resource read chunk exceeds 4 MiB');
                }
                return base64Encode(
                  bytes.sublist(
                    offset.clamp(0, bytes.length),
                    (offset + length).clamp(0, bytes.length),
                  ),
                );

              case 'text':
                output.add(values.single.toString());
                return null;
              case 'image':
                final bytes = base64Decode(values.first as String);
                final image = await prepareWorkspaceImage(
                  bytes,
                  '$workspace/script',
                );
                check();
                if (image == null) {
                  throw StateError('Unsupported or oversized image');
                }
                images.add(image);
                return null;
              case 'tool':
                final name = values[0] as String;
                final tool = exports[name];
                if (tool == null || tools == null) {
                  throw StateError('Tool unavailable: $name');
                }
                var childActive = true;
                late ToolOutput result;
                try {
                  result = await WorkspaceStore.guardCommits(
                    () => childActive && active(),
                    () => tools!.invoke(
                      tool.name,
                      Map<String, dynamic>.from(values[1] as Map),
                      () => childActive && active(),
                    ),
                  );
                } finally {
                  childActive = false;
                }
                check();
                if (result.isError) throw StateError(result.text);
                return {
                  'text': result.text,
                  'isError': result.isError,
                  'structured': result.structured,
                  'images': [
                    for (final image in result.images)
                      {
                        'mimeType': image.mimeType,
                        'base64': base64Encode(image.bytes),
                        'source': image.source,
                      },
                  ],
                };
              case 'fetch':
                final options = Map<String, dynamic>.from(values[1] as Map);
                final response = await network.fetch(
                  Uri.parse(values[0] as String),
                  method: (options['method'] as String?) ?? 'GET',
                  headers: {
                    for (final e in (options['headers'] as Map? ?? {}).entries)
                      e.key.toString(): e.value.toString(),
                  },
                  body: options['body'] == null
                      ? null
                      : utf8.encode(options['body'].toString()),
                  isActive: active,
                );
                check();
                return {
                  'url': response.url.toString(),
                  'status': response.status,
                  'headers': response.headers,
                  'base64': base64Encode(response.bytes),
                };
              case 'readBytes':
                if (store == null) {
                  throw StateError(
                    'No workspace granted; use tools with this run’s grants',
                  );
                }
                final path = values[0] as String;
                final offset = _integer(values[1]),
                    length = _integer(values[2]);
                if (offset < 0 || length < 0 || length > maxChunkBytes) {
                  throw ArgumentError('Byte read chunk exceeds 4 MiB');
                }
                final bytes = await store!.readRange(
                  workspace,
                  path,
                  offset: offset,
                  length: length,
                );
                check();
                return base64Encode(bytes);
              case 'writeBytes':
                if (store == null) {
                  throw StateError(
                    'No workspace granted; use tools with this run’s grants',
                  );
                }
                final path = values[0] as String;
                store!.checkWritablePath(workspace, path);
                final bytes = base64Decode(values[1] as String);
                if (bytes.length > maxChunkBytes) {
                  throw ArgumentError('Byte write chunk exceeds 4 MiB');
                }
                final offset = _integer(values[2]);
                final stat = await store!.stat(workspace, path);
                final (previous, revision) = stat == null
                    ? (Uint8List(0), null)
                    : await store!.read(workspace, path);
                if (offset < 0 ||
                    offset > previous.length ||
                    offset + bytes.length > WorkspaceLimits.maxFileBytes) {
                  throw ArgumentError('Invalid byte write offset or file size');
                }
                final truncate = values[3] as bool;
                final data = Uint8List(
                  truncate
                      ? offset + bytes.length
                      : (offset + bytes.length).clamp(
                          previous.length,
                          WorkspaceLimits.maxFileBytes,
                        ),
                );
                data.setAll(0, previous.take(data.length).toList());
                data.setAll(offset, bytes);
                check();
                final written = await store!.write(
                  workspace,
                  path,
                  data,
                  expectedRevision: revision,
                  runId: runId,
                );
                return {'revision': written.revision, 'size': written.size};
              default:
                throw StateError('Unknown script host method: $method');
            }
          },
        ),
      );
      captureReturn?.call(result);
      if (captureReturn == null && result != 'undefined') output.add(result);
    } catch (e) {
      error = '$e';
    } finally {
      network.close();
    }
    if (error != null) output.add(error);
    if (store == null) {
      return ToolOutput(
        text:
            utf8.decode(output.fileBytes).trimRight() +
            (output.fileTruncated ? '\nOutput truncated to last 8 MiB.' : ''),
        images: images,
        isError: error != null,
      );
    }
    var text = output.modelText;
    if (output.truncated) {
      if (isCancelled?.call() ?? false) {
        text +=
            'Output truncated; artifact not saved because invocation cancelled.';
      } else {
        final path = WorkspaceScriptOutput.artifactPath(runId);
        try {
          await WorkspaceStore.guardCommits(
            () => !(isCancelled?.call() ?? false),
            () => store!.write(
              workspace,
              path,
              output.fileBytes,
              runId: hostRunId,
              allowHost: true,
            ),
          );
          text +=
              'Output truncated; ${output.fileTruncated ? 'only the last 8 MiB retained; ' : ''}full output: $path';
        } catch (e) {
          error = 'Cannot save script output: $e';
          text += error;
        }
      }
    }
    // Footer and errors share the same model budget as stdout, not an extra
    // allowance that quietly makes a 50 KiB/2000-line result larger.
    return ToolOutput(
      text: WorkspaceScriptOutput.modelTail(text).trimRight(),
      images: images,
      isError: error != null,
    );
  }

  static int _integer(Object? value) {
    if (value is! int) throw ArgumentError('Expected integer');
    return value;
  }
}

const workspaceScriptUtilities = r'''
function __headers(values) { return Object.freeze({...values, get: name => values[String(name).toLowerCase()] ?? null, has: name => Object.prototype.hasOwnProperty.call(values, String(name).toLowerCase())}); }
function __format(value) { return typeof value === 'string' ? value : JSON.stringify(value); }
function __encode(bytes) {
  if (typeof bytes === 'string') return bytes;
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const pieces = [];
  for (let start = 0; start < bytes.length; start += 3072) {
    let part = '';
    for (let i = start; i < Math.min(start + 3072, bytes.length); i += 3) {
      const a = bytes[i], b = bytes[i+1] || 0, c = bytes[i+2] || 0;
      part += alphabet[a >> 2] + alphabet[((a & 3) << 4) | (b >> 4)] +
        (i+1 < bytes.length ? alphabet[((b & 15) << 2) | (c >> 6)] : '=') +
        (i+2 < bytes.length ? alphabet[c & 63] : '=');
    }
    pieces.push(part);
  }
  return pieces.join('');
}

function __decode(text) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const bytes = new Uint8Array((text.length * 3 >> 2) - (text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0));
  let bits = 0, count = 0, offset = 0;
  for (const char of text) {
    if (char === '=') break;
    bits = (bits << 6) | alphabet.indexOf(char); count += 6;
    if (count >= 8) { count -= 8; bytes[offset++] = (bits >> count) & 255; }
  }
  return bytes;
}
function __utf8(bytes) {
  // Decode bounded chunks, keeping multi-byte UTF-8 sequences together.
  const chunks = [];
  for (let start = 0; start < bytes.length;) {
    let end = Math.min(start + 4096, bytes.length);
    while (end < bytes.length && end > start && (bytes[end] & 0xc0) === 0x80) end--;
    if (end === start) throw new Error('Invalid UTF-8 response');
    let encoded = '';
    for (let i = start; i < end; i++) encoded += '%' + bytes[i].toString(16).padStart(2, '0');
    try { chunks.push(decodeURIComponent(encoded)); }
    catch (_) { throw new Error('Invalid UTF-8 response; use arrayBuffer()'); }
    start = end;
  }
  return chunks.join('');
}

''';

const _workspaceBootstrap =
    workspaceScriptUtilities +
    r'''
const text = (...values) => __aq_text(values.map(__format).join(' '));
const image = value => __aq_host('image', [__encode(value.base64 || value)]);
const console = Object.freeze(Object.fromEntries(['log','info','warn','error','debug'].map(name => [name, text])));
const tools = Object.create(null);
tools.list = () => __toolInfo;
tools.describe = name => __toolInfo.find(t => t.exportName === name || t.name === name || (t.names || []).includes(name)) || null;
for (const info of __toolInfo.filter(t => t.available)) tools[info.exportName] = (args = {}) => __aq_host('tool', [info.exportName, args]);
Object.freeze(tools);
const ws = Object.freeze({
  readBytes: (path, {offset = 0, length = 4194304} = {}) => __aq_host('readBytes', [path, offset, length]),
  writeBytes: (path, bytes, {offset = 0, truncate = offset === 0} = {}) => __aq_host('writeBytes', [path, __encode(bytes), offset, truncate]),
});
const skill = Object.freeze({
  list: () => __aq_host('resourceList', []),
  readBytes: (path, {offset = 0, length = 4194304} = {}) => __aq_host('resourceRead', [path, offset, length]),
  readText: async (path, options = {}) => __utf8(__decode(await __aq_host('resourceRead', [path, options.offset || 0, options.length === undefined ? 4194304 : options.length]))),
});
const fetch = async (url, options = {}) => {
  const r = await __aq_host('fetch', [String(url), options]);
  return Object.freeze({url: r.url, status: r.status, ok: r.status >= 200 && r.status < 300, headers: __headers(r.headers),
    arrayBuffer: async () => __decode(r.base64).buffer,
    text: async () => __utf8(__decode(r.base64)),
    json: async () => JSON.parse(__utf8(__decode(r.base64))),
  });
};
''';
