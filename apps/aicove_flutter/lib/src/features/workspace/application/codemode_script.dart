import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;
import 'package:aicove_quickjs/aicove_quickjs.dart';
import '../../../core/network/public_network.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../data/workspace_store.dart';
import '../domain/workspace_models.dart';
import 'codemode_declarations.dart';
import 'codemode_search.dart';
import 'codemode_source.dart';
import 'workspace_script.dart'
    show workspaceScriptUtilities, WorkspaceScriptOutput, WorkspaceScript;
import 'workspace_image.dart';

/// One Pi-style code invocation, using the existing asynchronous QuickJS host.
/// Tool execution stays in the agent's pipeline; this class owns only JS I/O.
class CodemodeScript {
  CodemodeScript({
    required this.store,
    required this.workspace,
    required this.runId,
    required this.owner,
    this.tools,
    this.isCancelled,
    this.callId = 'codemode',
    PublicNetwork Function()? networkFactory,
  }) : _networkFactory = networkFactory ?? PublicNetwork.new;
  final WorkspaceStore store;
  final String? Function() workspace;
  final String runId, owner, callId;
  final ScriptToolAccess? tools;
  final bool Function()? isCancelled;
  final PublicNetwork Function() _networkFactory;
  static int _stateSequence = 0;
  static final _stateQueues = <String, Future<void>>{};

  Future<ToolOutput> run(String input) async {
    final stateFile = File(
      '${store.root.path}/.codemode-state/${base64Url.encode(utf8.encode(owner)).replaceAll('=', '')}.json',
    );
    // Scripts for one session see committed writes in invocation order.
    final previous = _stateQueues[stateFile.path] ?? Future<void>.value();
    final done = Completer<void>();
    final queued = previous.then((_) => done.future);
    _stateQueues[stateFile.path] = queued;
    try {
      await previous;
      return await _run(input, stateFile);
    } finally {
      done.complete();
      if (identical(_stateQueues[stateFile.path], queued))
        _stateQueues.remove(stateFile.path);
    }
  }

  Future<ToolOutput> _run(String input, File stateFile) async {
    final watch = Stopwatch()..start();
    final items = <String>[], console = <String>[];
    final calls = <Map<String, dynamic>>[];
    final cancellations = <KernelCancellation>[];
    final images = <ToolImage>[];
    final network = _networkFactory();
    String? error, fullPath;
    var maxTokens = 10000;
    Duration? deadline;
    var active = true;
    void check() {
      if (!active || (isCancelled?.call() ?? false))
        throw StateError('Script aborted');
    }

    String cwd() =>
        workspace() ?? (throw StateError('No current workspace granted'));
    String trim(String text, int length) =>
        text.length > length ? text.substring(0, length) : text;
    final catalog = (tools?.tools ?? const <AITool>[])
        .where((t) => t.name != 'codemode')
        .toList();
    final exports = WorkspaceScript.exportedTools(catalog);
    final search = CodemodeSearch(catalog);
    void stop() {
      active = false;
      network.close();
      for (final signal in cancellations) {
        signal.cancel();
      }
      for (final call in calls) {
        if (call['status'] == 'running') call['status'] = 'cancelled';
      }
    }

    try {
      final parsed = parseCodemodeSource(input);
      maxTokens = parsed.maxOutputTokens;
      deadline = parsed.timeout;
      check();
      final state = await stateFile.exists()
          ? jsonDecode(await stateFile.readAsString())
          : <String, dynamic>{};
      final session = QuickJsAsyncSession();
      final result = await session.run(
        '''
$workspaceScriptUtilities
const __catalog = ${jsonEncode([
          for (final tool in catalog) {...describeCodemodeTool(tool), 'exportName': toCodemodeIdentifier(tool.name), 'structured': tool.outputSchema != null},
        ])};
const __state = ${jsonEncode(state)};
const __callId = ${jsonEncode(callId)};
$_bootstrap
try {
  const value = await (async () => {\n${parsed.code}\n})();
  if (value !== undefined) text(value);
} catch (e) { if (e !== __exit) throw new Error(e.stack ? String(e) + '\\n' + e.stack : String(e)); }
return JSON.stringify(__state);
''',
        timeout: parsed.timeout,
        isCancelled: isCancelled,
        onStop: stop,
        onText: (packet) {
          final data = jsonDecode(packet) as Map;
          if (data['kind'] == 'call') {
            calls.add(Map<String, dynamic>.from(data['value'] as Map));
          } else {
            (data['kind'] == 'console' ? console : items).add(
              data['value'] as String,
            );
          }
        },
        hostCall: (method, args, sessionActive) => WorkspaceStore.guardCommits(
          () => active && sessionActive() && !(isCancelled?.call() ?? false),
          () async {
            check();
            switch (method) {
              case 'tool':
                final tool = exports[args[0]];
                if (tool == null || tools == null)
                  throw StateError('Tool unavailable: ${args[0]}');
                final arguments = Map<String, dynamic>.from(args[1] as Map);
                final signal = KernelCancellation();
                cancellations.add(signal);
                final call = calls.firstWhere((c) => c['id'] == args[2]);
                final timer = Stopwatch()..start();
                try {
                  final output = await tools!.execute(
                    tool.name,
                    arguments,
                    () => active && sessionActive() && !signal.isCancelled,
                    cancellation: signal,
                    callId: call['id'] as String,
                  );
                  check();
                  if (output.isError) throw StateError(output.text);
                  call['status'] = 'ok';
                  if (tool.outputSchema != null) return output.structured;
                  return output.text;
                } catch (e) {
                  call['status'] = signal.isCancelled || !active
                      ? 'cancelled'
                      : 'error';
                  call['error'] = trim('$e', 300);
                  rethrow;
                } finally {
                  call['durationMs'] = timer.elapsedMilliseconds;
                }
              case 'search':
                final options = Map<String, dynamic>.from(args[1] as Map);
                return search.search(
                  args[0] as String,
                  limit: options['limit'] as int? ?? 8,
                  namespace: options['namespace'] as String?,
                );
              case 'describe':
                final tool = catalog
                    .where(
                      (t) =>
                          t.name == args[0] ||
                          toCodemodeIdentifier(t.name) == args[0],
                    )
                    .firstOrNull;
                if (tool == null)
                  throw StateError('Tool unavailable: ${args[0]}');
                return describeCodemodeTool(tool);
              case 'namespace':
                return [
                  for (final tool in catalog)
                    if (toolNamespace(tool) == args[0])
                      describeCodemodeTool(tool),
                ];
              case 'fetch':
                final options = Map<String, dynamic>.from(args[1] as Map);
                final response = await network.fetch(
                  Uri.parse(args[0] as String),
                  method: options['method'] as String? ?? 'GET',
                  headers: {
                    for (final e in (options['headers'] as Map? ?? {}).entries)
                      '${e.key}': '${e.value}',
                  },
                  body: options['body'] == null
                      ? null
                      : utf8.encode('${options['body']}'),
                  isActive: () => active && sessionActive(),
                );
                check();
                return {
                  'url': '${response.url}',
                  'status': response.status,
                  'headers': response.headers,
                  'base64': base64Encode(response.bytes),
                };
              case 'readBytes':
                final offset = args[1] as int, length = args[2] as int;
                if (offset < 0 || length < 0 || length > 4 * 1024 * 1024)
                  throw ArgumentError('Read chunk exceeds 4 MiB');
                return base64Encode(
                  await store.readRange(
                    cwd(),
                    args[0] as String,
                    offset: offset,
                    length: length,
                  ),
                );
              case 'writeBytes':
                final ws = cwd(),
                    path = args[0] as String,
                    bytes = base64Decode(args[1] as String),
                    offset = args[2] as int;
                store.checkWritablePath(ws, path);
                if (bytes.length > 4 * 1024 * 1024)
                  throw ArgumentError('Write chunk exceeds 4 MiB');
                final stat = await store.stat(ws, path);
                final (previous, revision) = stat == null
                    ? (Uint8List(0), null)
                    : await store.read(ws, path);
                if (offset < 0 ||
                    offset > previous.length ||
                    offset + bytes.length > WorkspaceLimits.maxFileBytes)
                  throw ArgumentError('Invalid write offset or size');
                final data = Uint8List(
                  args[3] == true
                      ? offset + bytes.length
                      : (offset + bytes.length).clamp(
                          previous.length,
                          WorkspaceLimits.maxFileBytes,
                        ),
                );
                data.setAll(0, previous.take(data.length).toList());
                data.setAll(offset, bytes);
                check();
                final saved = await store.write(
                  ws,
                  path,
                  data,
                  expectedRevision: revision,
                  runId: runId,
                );
                return {'revision': saved.revision, 'size': saved.size};
              case 'image':
                final encoded = args[0] as String;
                final image = await prepareWorkspaceImage(
                  base64Decode(encoded),
                  '${cwd()}/codemode',
                );
                if (image == null) throw StateError('Unsupported image');
                final path =
                    '${WorkspaceScriptOutput.artifactPath(runId)}.${image.mimeType.split('/').last}';
                await store.write(
                  cwd(),
                  path,
                  image.bytes,
                  runId: hostRunId,
                  allowHost: true,
                );
                check();
                images.add(image);
                items.add('Image saved: $path');
                return path;
              default:
                throw StateError('Unknown host method: $method');
            }
          },
        ),
      );
      // QuickJS has stopped; committing state uses only the outer cancellation.
      if (isCancelled?.call() ?? false) throw StateError('Script aborted');
      final next = jsonDecode(result) as Map;
      if (jsonEncode(next).length > 1048576 ||
          next.values.any((v) => jsonEncode(v).length > 262144))
        throw StateError('store size limit exceeded');
      if (jsonEncode(next) != jsonEncode(state)) {
        await stateFile.parent.create(recursive: true);
        final temp = File('${stateFile.path}.${++_stateSequence}.tmp');
        await temp.writeAsString(jsonEncode(next), flush: true);
        if (isCancelled?.call() ?? false) {
          await temp.delete();
          throw StateError('Script aborted');
        }
        await temp.rename(stateFile.path);
      }
    } catch (e) {
      error =
          e is TimeoutException ||
              (deadline != null &&
                  watch.elapsed >= deadline &&
                  !(isCancelled?.call() ?? false))
          ? 'Script timed out'
          : (isCancelled?.call() ?? false)
          ? 'Script aborted'
          : '$e';
    } finally {
      stop();
    }
    final output = [
      for (var i = 0; i < items.length; i++)
        '${items.length > 1 ? '==> text ${i + 1}/${items.length} <==\n' : ''}${items[i]}',
      if (console.isNotEmpty)
        '<console_output>\n${console.join('\n')}\n</console_output>',
    ].join('\n');
    var shown = output;
    final maxChars = maxTokens * 4;
    if (output.length > maxChars) {
      try {
        fullPath = WorkspaceScriptOutput.artifactPath(runId);
        await store.write(
          cwd(),
          fullPath,
          utf8.encode(output),
          runId: hostRunId,
          allowHost: true,
        );
        final head = maxChars ~/ 2, tail = maxChars - head;
        shown =
            '${output.substring(0, head)}\n[Output truncated; full output: $fullPath]\n${output.substring(output.length - tail)}';
      } catch (e) {
        error = '${error == null ? '' : '$error\n'}Cannot save full output: $e';
      }
    }
    final text = [
      'Script ${error == null ? 'completed' : 'failed'}',
      'Wall time ${(watch.elapsedMicroseconds / 1000000).toStringAsFixed(1)} seconds',
      'Output:',
      shown,
      if (error != null) 'Script error:\n$error',
      if (calls.isNotEmpty)
        '\nNested calls:\n${calls.map((c) => '${c['name']} ${c['status']} ${c['durationMs'] ?? 0}ms${c['error'] == null ? '' : ' ${c['error']}'}').join('\n')}',
    ].join('\n');
    return ToolOutput(
      text: text,
      images: images,
      isError: error != null,
      structured: {
        'codemodeCalls': calls,
        if (fullPath != null) 'fullOutputPath': fullPath,
      },
    );
  }
}

const _bootstrap = r'''
const __exit = Object.freeze({});
const exit = () => { throw __exit; };
const __fmt = value => typeof value === 'string' ? value : value === undefined ? 'undefined' : JSON.stringify(value);
const text = value => __aq_text(JSON.stringify({kind:'text',value:__fmt(value)}));
const console = Object.freeze(Object.fromEntries(['log','info','warn','error','debug'].map(name=>[name,(...values)=>__aq_text(JSON.stringify({kind:'console',value:values.map(__fmt).join(' ')}))])));
const store = (key,value) => {
  if(typeof key !== 'string') throw new Error('store key must be a string');
  if(value === undefined) { delete __state[key]; return; }
  const encoded=JSON.stringify(value);
  if(encoded===undefined || encoded.length>262144) throw new Error('store value exceeds 262144 characters');
  const next={...__state,[key]:JSON.parse(encoded)};
  if(JSON.stringify(next).length>1048576) throw new Error('store total exceeds 1048576 characters');
  Object.defineProperty(__state,key,{value:JSON.parse(encoded),enumerable:true,writable:true,configurable:true});
};
const load = key => __state[key] === undefined ? undefined : JSON.parse(JSON.stringify(__state[key]));
const ALL_TOOLS = Object.freeze(__catalog.map(({name,description,namespace})=>Object.freeze({name,description,namespace})));
const tools = Object.create(null);
let __callSequence=0;
for(const info of __catalog) tools[info.exportName]=(args={})=>{
  const id=__callId+'/'+(++__callSequence);
  __aq_text(JSON.stringify({kind:'call',value:{id,name:info.name,args:JSON.stringify(args).slice(0,200),status:'running'}}));
  return __aq_host('tool',[info.exportName,args,id]);
};
Object.freeze(tools);
const searchTools = (q,options={})=>__aq_host('search',[String(q),options]);
const describeTool = name=>__aq_host('describe',[String(name)]);
const describeNamespace = name=>__aq_host('namespace',[String(name)]);
const image = value => {
  const data=typeof value==='object'?(value.data || value.base64 || value.image_url || value):value;
  return __aq_host('image',[typeof data==='string'?data.replace(/^data:[^;]+;base64,/,''):__encode(data)]);
};
const ws = Object.freeze({
  readBytes:(path,{offset=0,length=4194304}={})=>__aq_host('readBytes',[path,offset,length]),
  writeBytes:(path,bytes,{offset=0,truncate=offset===0}={})=>__aq_host('writeBytes',[path,__encode(bytes),offset,truncate]),
});
const fetch=async(url,options={})=>{
  const r=await __aq_host('fetch',[String(url),options]);
  return Object.freeze({url:r.url,status:r.status,ok:r.status>=200&&r.status<300,headers:__headers(r.headers),
    arrayBuffer:async()=>__decode(r.base64).buffer,text:async()=>__utf8(__decode(r.base64)),json:async()=>JSON.parse(__utf8(__decode(r.base64)))});
};
''';
