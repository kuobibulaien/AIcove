import 'dart:convert';
import 'package:archive/archive.dart';

Map<String, List<int>> skillFiles({String name = 'Sample Skill'}) => {
  'SKILL.md': utf8.encode(
    '---\nname: $name\ndescription: Read the reference and run the script.\n---\nUse scripts/answer.js; return its exact result.',
  ),
  'scripts/answer.js': utf8.encode(
    'text((await skill.readText("references/value.txt")).trim() + ":" + args.suffix);',
  ),
  'references/value.txt': utf8.encode('resource-secret\nsecond\nthird'),
  'assets/template.bin': [0, 1, 255],
  '.config/template.txt': utf8.encode('hidden resource'),
};

Map<String, List<int>> scriptFiles(String source, {String id = 'demo'}) => {
  'aicove-package.json': utf8.encode(
    jsonEncode({
      'schema': 1,
      'id': id,
      'name': id,
      'version': '1',
      'contents': [
        {'type': 'prompt', 'text': 'package-prompt'},
        {'type': 'script', 'main': 'plugin.js'},
      ],
    }),
  ),
  'plugin.js': utf8.encode(source),
};

const scriptSource = '''
let counter = 0;
aicove.appendPrompt('script-prompt');
aicove.registerTool({name: 'answer', description: 'Return a computed value',
  inputSchema: {type:'object', properties: {value:{type:'integer'}, fail:{type:'boolean'}, loop:{type:'boolean'}, heap:{type:'boolean'}}, required:['value']},
  handler: async input => {
    if (input.fail) throw new Error('intentional-failure');
    if (input.loop) while(true) {}
    if (input.heap) return new ArrayBuffer(128 * 1024 * 1024);
    counter++;
    text('count:' + counter);
    return input.value * 3;
  }
});
''';

List<int> zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value)..name = e.key);
  }
  return ZipEncoder().encode(archive)!;
}
