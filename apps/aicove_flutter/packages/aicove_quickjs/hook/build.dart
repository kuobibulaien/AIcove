import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await CBuilder.library(
      name: 'aicove_quickjs',
      assetName: 'src/bindings.dart',
      sources: [
        'src/bridge.c',
        for (final name in [
          'quickjs',
          'dtoa',
          'libregexp',
          'libunicode',
          'cutils',
        ])
          'src/quickjs/$name.c',
      ],
      includes: ['src/quickjs'],
      defines: {'_GNU_SOURCE': null, 'CONFIG_VERSION': '"2026-06-04"'},
      flags: ['-fwrapv'],
      libraries: [
        if (input.config.code.targetOS == OS.android ||
            input.config.code.targetOS == OS.linux)
          'm',
      ],
    ).run(input: input, output: output);
  });
}
