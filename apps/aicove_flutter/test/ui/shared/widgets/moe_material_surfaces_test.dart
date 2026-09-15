import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

Widget materialApp(MoeSurfaceMaterial mode, Widget child, {bool dark = false}) =>
    MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light,
          extensions: [dark ? MoeColors.dark() : MoeColors.light()]),
      builder: (context, child) => MoeGlassTheme(
        enabled: mode != MoeSurfaceMaterial.solid,
        useLiquidGlass: mode == MoeSurfaceMaterial.liquid,
        blurSigma: 16,
        child: child!,
      ),
      home: Scaffold(body: child),
    );

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final dark in [false, true]) {
      for (final mode in MoeSurfaceMaterial.values) {
        testWidgets('shared surfaces $mode width=$width dark=$dark', (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          MoeLiquidGlassService.setMockState(available: true);
          final capture = GlobalKey();
          await tester.pumpWidget(materialApp(mode, RepaintBoundary(
            key: capture,
            child: Stack(children: [
              const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFF6FA4AD), Color(0xFFF6C0A2), Color(0xFF8AB47E)])))),
              SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
                MoeFloatingSurface(radius: 28, child: Padding(padding: const EdgeInsets.all(16),
                    child: Text('背景材质 · ${mode.label}'))),
                const SizedBox(height: 16),
                MoeSearchField(hintText: '搜索联系人', onChanged: (_) {}),
                const SizedBox(height: 16),
                const MoeSettingsGroup(margin: EdgeInsets.zero, children: [
                  MoeSettingsRow(icon: Icons.palette_outlined, label: '界面设置'),
                  MoeSettingsRow(icon: Icons.person_outline, label: '角色资料'),
                ]),
                const SizedBox(height: 16),
                const MoeBottomSheet(title: '选择预设', maxHeight: 220, child: ListTile(title: Text('示例预设'))),
                const SizedBox(height: 16),
                MoeActionSheet(actions: [MoeSheetAction(label: '复制', onTap: () {})]),
              ]))),
            ]),
          ), dark: dark));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (mode == MoeSurfaceMaterial.solid) {
            expect(find.byType(BackdropFilter), findsNothing);
            expect(find.byType(AdaptiveGlass), findsNothing);
          } else if (mode == MoeSurfaceMaterial.frosted) {
            expect(find.byType(BackdropFilter), findsWidgets);
            expect(find.byType(AdaptiveGlass), findsNothing);
          } else {
            expect(find.byType(AdaptiveGlass), findsWidgets);
          }
          if (const bool.fromEnvironment('WRITE_MATERIAL_QA')) {
            final boundary = capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              final file = File('../../.codex-temp/material-three-states/qa/${mode.name}-${width.toInt()}-${dark ? 'dark' : 'light'}.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }

  testWidgets('switching material keeps an internally owned draft and focus', (tester) async {
    final mode = ValueNotifier(MoeSurfaceMaterial.solid);
    addTearDown(mode.dispose);
    await tester.pumpWidget(ValueListenableBuilder(
      valueListenable: mode,
      builder: (_, value, __) => materialApp(value,
          const MoeFloatingSurface(child: _Draft())),
    ));
    await tester.enterText(find.byType(TextField), '未保存的草稿');
    final original = tester.state(find.byType(_Draft));
    for (final value in [MoeSurfaceMaterial.frosted, MoeSurfaceMaterial.liquid, MoeSurfaceMaterial.solid]) {
      mode.value = value;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Draft)), same(original));
      expect(find.text('未保存的草稿'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('reduce transparency removes both glass pipelines', (tester) async {
    await tester.pumpWidget(materialApp(MoeSurfaceMaterial.liquid,
      GlassAccessibilityScope(
        reduceTransparency: true,
        child: const MoeFloatingSurface(child: Text('不透明背景')),
      ),
    ));
    expect(find.byType(AdaptiveGlass), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });
}

class _Draft extends StatefulWidget {
  const _Draft();
  @override
  State<_Draft> createState() => _DraftState();
}
class _DraftState extends State<_Draft> {
  final controller = TextEditingController();
  final focus = FocusNode();
  @override
  void dispose() { controller.dispose(); focus.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => TextField(controller: controller, focusNode: focus);
}
