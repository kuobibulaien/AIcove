import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _assetName = 'src/bindings.dart';
const _quickJsVersion = '2026-06-04';
const _sources = [
  'src/bridge.c',
  'src/quickjs/quickjs.c',
  'src/quickjs/dtoa.c',
  'src/quickjs/libregexp.c',
  'src/quickjs/libunicode.c',
  'src/quickjs/cutils.c',
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.config.code.targetOS == OS.windows) {
      await _buildWindows(input, output);
      return;
    }
    await CBuilder.library(
      name: 'aicove_quickjs',
      assetName: _assetName,
      sources: _sources,
      includes: ['src/quickjs'],
      defines: {'_GNU_SOURCE': null, 'CONFIG_VERSION': '"$_quickJsVersion"'},
      flags: ['-fwrapv'],
      libraries: [
        if (input.config.code.targetOS == OS.android ||
            input.config.code.targetOS == OS.linux)
          'm',
      ],
    ).run(input: input, output: output);
  });
}

/// QuickJS relies on GCC/Clang extensions (computed goto, __builtin_*,
/// __attribute__) and POSIX headers, so MSVC's cl.exe cannot compile it.
/// On Windows we build with clang-cl inside the MSVC developer environment
/// and supply a small POSIX shim (src/win_compat) instead.
Future<void> _buildWindows(BuildInput input, BuildOutputBuilder output) async {
  final compiler = input.config.code.cCompiler;
  final prompt = compiler?.windows.developerCommandPrompt;
  final environment = prompt == null
      ? <String, String>{}
      : await _batchEnvironment(prompt.script, prompt.arguments);
  final clang = _findClangCl(compiler?.compiler, environment);
  final target = switch (input.config.code.targetArchitecture) {
    Architecture.arm64 => 'aarch64-pc-windows-msvc',
    Architecture.ia32 => 'i686-pc-windows-msvc',
    _ => 'x86_64-pc-windows-msvc',
  };

  final root = input.packageRoot;
  final outDir = input.outputDirectory;
  final objDir = outDir.resolve('obj/');
  await Directory.fromUri(objDir).create(recursive: true);
  final config = File.fromUri(outDir.resolve('aicove_quickjs_config.h'));
  await config.writeAsString('#define CONFIG_VERSION "$_quickJsVersion"\n');
  final dll = outDir.resolve('aicove_quickjs.dll');
  final engine = await _patchEnumBitfields(
    File.fromUri(root.resolve('src/quickjs/quickjs.c')),
    File.fromUri(outDir.resolve('quickjs_msvc_abi.c')),
  );
  final sources = [
    for (final source in _sources)
      if (source == 'src/quickjs/quickjs.c') engine.path else root.resolve(source).toFilePath(),
    root.resolve('src/win_compat/win_compat.c').toFilePath(),
  ];

  final builtins = await _findClangBuiltins(clang, target, environment);
  final result = await Process.run(
    clang.toFilePath(),
    [
      '--target=$target',
      '/nologo',
      '/O2',
      '/MD',
      '/LD',
      '/w',
      '/clang:-fwrapv',
      '/DNDEBUG',
      '/D_GNU_SOURCE',
      '/FI${root.resolve('src/win_compat/prelude.h').toFilePath()}',
      '/FI${config.path}',
      '/I${root.resolve('src/win_compat').toFilePath()}',
      '/I${root.resolve('src/quickjs').toFilePath()}',
      ...sources,
      '/Fo${objDir.toFilePath()}',
      '/Fe${dll.toFilePath()}',
      '/link',
      '/NOIMPLIB',
      '/NOEXP',
      // 128-bit division in dtoa.c needs compiler-rt (__udivti3).
      builtins.toFilePath(),
    ],
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw Exception(
      'clang-cl failed (${result.exitCode}):\n${result.stdout}\n${result.stderr}',
    );
  }

  output.dependencies.addAll([
    for (final source in _sources) root.resolve(source),
    root.resolve('src/win_compat/win_compat.c'),
    root.resolve('src/win_compat/prelude.h'),
    root.resolve('src/win_compat/pthread.h'),
    root.resolve('src/win_compat/sys/time.h'),
  ]);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: dll,
    ),
  );
}

/// In the Microsoft ABI an enum bit-field is signed, so
/// `JSClosureTypeEnum closure_type : 3` reads values 4-7 back as negative and
/// js_closure2() aborts on the first global variable access. GCC/Clang on
/// other targets treat these fields as unsigned. Compile a copy with the enum
/// bit-fields declared `unsigned int` (same storage unit, so the layout is
/// unchanged); the vendored file itself stays untouched.
Future<File> _patchEnumBitfields(File source, File target) async {
  final pattern = RegExp(
    r'^(\s+)(?:\w+Enum|JSModuleStatus)(\s+\w+\s*:\s*\d+\s*;)',
    multiLine: true,
  );
  final text = await source.readAsString();
  final patched = text.replaceAllMapped(
    pattern,
    (m) => '${m[1]}unsigned int${m[2]}',
  );
  if (!patched.contains('unsigned int closure_type : 3;')) {
    throw Exception(
      'aicove_quickjs: closure_type bit-field not found; re-check the '
      'Windows enum bit-field patch after a QuickJS upgrade',
    );
  }
  await target.writeAsString(patched);
  return target;
}

Future<Uri> _findClangBuiltins(
  Uri clang,
  String target,
  Map<String, String> environment,
) async {
  final printed = await Process.run(clang.toFilePath(), [
    '/clang:-print-resource-dir',
  ], environment: environment);
  final resourceDir = Directory(
    '${(printed.stdout as String).trim()}${Platform.pathSeparator}lib',
  );
  final arch = target.split('-').first;
  if (resourceDir.existsSync()) {
    for (final entity in resourceDir.listSync(recursive: true)) {
      final name = entity.uri.pathSegments.last;
      final perTarget = name == 'clang_rt.builtins.lib' && entity.path.contains(target);
      if (perTarget || name == 'clang_rt.builtins-$arch.lib') return entity.uri;
    }
  }
  throw Exception(
    'aicove_quickjs: clang_rt.builtins for $target not found under ${resourceDir.path}',
  );
}

Uri _findClangCl(Uri? msvcCompiler, Map<String, String> environment) {
  final candidates = <String>[
    if (environment['VCINSTALLDIR'] case final vc?) ...[
      '${vc}Tools\\Llvm\\x64\\bin\\clang-cl.exe',
      '${vc}Tools\\Llvm\\bin\\clang-cl.exe',
    ],
    // cl.exe lives in VC\Tools\MSVC\<version>\bin\Host<arch>\<arch>\.
    if (msvcCompiler != null) ...[
      msvcCompiler.resolve('../../../../../Llvm/x64/bin/clang-cl.exe').toFilePath(),
      msvcCompiler.resolve('../../../../../Llvm/bin/clang-cl.exe').toFilePath(),
    ],
    r'C:\Program Files\LLVM\bin\clang-cl.exe',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return File(candidate).uri;
  }
  final where = Process.runSync('where', ['clang-cl'], runInShell: true);
  if (where.exitCode == 0) {
    return File((where.stdout as String).split(RegExp(r'\r?\n')).first.trim()).uri;
  }
  throw Exception(
    'aicove_quickjs needs clang-cl on Windows. Install the Visual Studio '
    'component "C++ Clang tools for Windows" or LLVM. Searched: $candidates',
  );
}

/// Environment variables added or changed by a Visual Studio vcvars script.
Future<Map<String, String>> _batchEnvironment(
  Uri script,
  List<String> arguments,
) async {
  const separator = '=======';
  // Run from the script's directory by file name: cmd.exe mangles quoted
  // paths containing spaces when they arrive through Process.run.
  final result = await Process.run(
    'set && echo $separator && ${script.pathSegments.last} ${arguments.join(' ')} > nul && set',
    [],
    runInShell: true,
    workingDirectory: script.resolve('.').toFilePath(),
  );
  if (result.exitCode != 0) {
    throw Exception('vcvars failed: ${result.stderr}');
  }
  final parts = (result.stdout as String).split(separator);
  Map<String, String> parse(String text) => {
    for (final line in text.trim().split(RegExp(r'\r?\n')))
      if (line.indexOf('=') case final i when i > 0)
        line.substring(0, i): line.substring(i + 1),
  };
  final before = parse(parts.first);
  final after = parse(parts.last);
  return {
    for (final MapEntry(:key, :value) in after.entries)
      if (before[key] != value) key: value,
  };
}
