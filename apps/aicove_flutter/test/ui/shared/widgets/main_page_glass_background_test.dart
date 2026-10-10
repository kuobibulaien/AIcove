import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/custom_bottom_nav.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_button_surface.dart';
import 'package:aicove_flutter/src/ui/features/home/pages/main_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_liquid_glass.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _EmptyConversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [];
}

void main() {
  const capture = bool.fromEnvironment('WRITE_ROOT_GLASS_QA');
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('RootCapture');
    font.addFont(
      File(
        '/System/Library/Fonts/STHeiti Medium.ttc',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(
      File(
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await icons.load();
  });

  for (final width in [420.0, 1000.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'root background and empty-state controls share material: $dark $width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 800);
          addTearDown(tester.view.reset);
          MoeLiquidGlassService.setMockState(available: true);
          final key = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                conversationsProvider.overrideWith(_EmptyConversations.new),
              ],
              child: MaterialApp(
                theme: ThemeData(
                  fontFamily: capture ? 'RootCapture' : null,
                  brightness: dark ? Brightness.dark : Brightness.light,
                  extensions: [dark ? MoeColors.dark() : MoeColors.light()],
                ),
                home: MoeGlassTheme(
                  enabled: true,
                  useLiquidGlass: true,
                  blurSigma: 16,
                  child: RepaintBoundary(
                    key: key,
                    child: MoeWorkspace(
                      navigatorKey: GlobalKey<NavigatorState>(),
                      isWide: width >= 900,
                      isDetail: false,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: width >= 900 ? 360 : width,
                          child: const MainPage(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final root = tester.widget<MoeFloatingSurface>(
            find.byType(MoeFloatingSurface).first,
          );
          expect(root.useLiquid, isFalse);
          expect(root.border, BorderSide.none);
          expect(root.radius, width >= 900 ? telegramPrimaryRadius : 0);
          for (final lens in find.byType(MoeLiquidGlass).evaluate()) {
            expect((lens.renderObject as RenderBox).size.height, lessThan(800));
          }
          expect(root.shadows, isEmpty);
          if (width >= 900) {
            expect(root.blurEnabled, isNull);
            expect(find.byType(BackdropFilter), findsWidgets);
          } else {
            // Full-screen narrow roots paint the plain page color.
            expect(root.blurEnabled, isFalse);
          }
          // The empty contact list has no search field. Its navigation buttons
          // inherit the root surface instead of creating duplicate lens layers.
          expect(find.text('暂无角色'), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          final navigation = find.byType(CustomBottomNav);
          expect(find.descendant(of: navigation,
              matching: find.byType(MoeButtonSurface)), findsNothing);
          expect(find.descendant(of: navigation,
              matching: find.byType(MoeFloatingSurface)), findsNothing);
          expect(find.byType(MoeLiquidGlass), findsNothing);
          expect(tester.takeException(), isNull);
          if (capture) {
            await tester.runAsync(() async {
              final boundary =
                  key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../../.codex-temp/root-glass/${dark ? 'dark' : 'light'}-${width.toInt()}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }
}
