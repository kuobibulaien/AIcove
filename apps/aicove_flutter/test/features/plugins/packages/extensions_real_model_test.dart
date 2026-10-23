// Opt-in ADR0103 acceptance. Credentials are read only from the environment.
@Tags(['real_model'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/features/plugins/packages/aicove_package.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'extension_test_support.dart';

final _key = Platform.environment['DEEPSEEK_API_KEY'];

void main() {
  Future<TaskRunOutcome> run(
    List<PackagePlugin> plugins,
    String instruction,
  ) async {
    final root = await Directory.systemTemp.createTemp('extension_real_');
    addTearDown(() => root.delete(recursive: true));
    final api = createApiRunner();
    final runner = TaskAgentRunner(
      loadSettings: () async => mapUiModelsToAppSettings({}),
      resultStore: ToolResultStore(
        () async => Directory('${root.path}/results'),
      ),
      requestConfig: ({required settings, required modelRef}) async =>
          BackgroundAgentRequestConfig(
            modelFullId: 'openai:deepseek-flash',
            providerApiBase: 'https://api.deepseek.com',
            providerApiKey: _key,
            customConfig: const {},
            modelTemperature: 0,
            modelTopP: null,
            modelContextMessageLimit: null,
          ),
      executor:
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) => api.executeApiCall(
            config: config,
            sessionId: sessionId,
            userText: null,
            responseProcessors: const [],
            availableTools: tools,
            cancellation: cancellation,
          ),
    );
    final capabilities = await resolveTaskPluginCapabilities(plugins, {
      for (final p in plugins) p.id,
    });
    return runner.run(
      taskId: 'extension-real',
      runId: 'extension-real-run',
      transcript: instruction,
      capabilities: capabilities,
      preset: const TaskAgentPreset(),
      cancellation: KernelCancellation(),
    );
  }

  test(
    'delegated agent reads role skill and completes the reference task',
    () async {
      final plugin = PackagePlugin(
        AicovePackage.parse({
          ...skillFiles(),
          'SKILL.md': utf8.encode(
            '---\nname: Sample Skill\ndescription: Read a reference to answer a task.\n---\n'
            'First read references/value.txt using the skill read tool. Return exactly its third line. Do not run any scripts.',
          ),
        }),
      );
      final result = await run([plugin], '请读取角色开启的 sample-skill 技能，严格按说明完成任务。');
      expect(result.summary, contains('third'));
      expect(result.processLog, contains('read_skill_sample-skill'));
      expect(result.processLog, contains('references/value.txt'));
      // ignore: avoid_print
      print('real(a): ${result.summary}; role skill and reference were read');
    },
    skip: _key == null || _key!.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'model calls registered plugin tool and uses its return value',
    () async {
      final plugin = PackagePlugin(
        AicovePackage.parse(scriptFiles(scriptSource)),
      );
      final result = await run([
        plugin,
      ], '必须调用 pkg_4_demo_answer，value 为 41。只回复工具实际返回的最终数字。');
      expect(result.processLog, contains('pkg_4_demo_answer'));
      expect(result.summary, contains('123'));
      // ignore: avoid_print
      print(
        'real(b): ${result.summary}; registered plugin handler returned 123',
      );
    },
    skip: _key == null || _key!.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'model runs a skill JS file and uses its private resource result',
    () async {
      final plugin = PackagePlugin(AicovePackage.parse(skillFiles()));
      final result = await run(
        [plugin],
        '先读取 sample-skill 技能，再运行它的 scripts/answer.js，args 为 {"suffix":"live-verified"}。'
        '不要用其他方式读取参考文件。请原样给出脚本实际输出。',
      );
      expect(result.processLog, contains('run_skill_js_sample-skill'));
      expect(result.summary, contains('resource-secret'));
      expect(result.summary, contains('third:live-verified'));
      // ignore: avoid_print
      print(
        'real(c): ${result.summary}; skill JS ran with read-only resource access',
      );
    },
    skip: _key == null || _key!.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
