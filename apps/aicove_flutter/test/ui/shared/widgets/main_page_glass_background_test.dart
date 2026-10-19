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
import 'package:aicove_flutter/src/ui/shared/widgets/moe_search_field.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_chat_wallpaper.dart';
import 'package:aicove_flutter/src/ui/theme/moe_wallpaper.dart';
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
        'root background follows the full material: $dark $width',
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
          // The root follows the global material in full, lens rim included.
          expect(root.useLiquid, isNull);
          expect(root.border, BorderSide.none);
          expect(root.radius, width >= 900 ? telegramPrimaryRadius : 0);
          expect(root.shadows, isEmpty);
          final rootLens = find.descendant(
            of: find.byWidget(root),
            matching: find.byType(MoeLiquidGlass),
          );
          if (width >= 900) {
            expect(root.blurEnabled, isNull);
            // The wide root pane is one full-height liquid surface.
            final lens = tester.widget<MoeLiquidGlass>(rootLens.first);
            expect(
              tester.getSize(rootLens.first),
              const Size(360, 800),
            );
            expect(lens.border, BorderSide.none);
            expect(lens.shadows, isEmpty);
            expect(lens.baseline, MoeMaterialBaseline.background);
          } else {
            // Full-screen narrow roots paint the plain page color.
            expect(root.blurEnabled, isFalse);
            for (final lens in find.byType(MoeLiquidGlass).evaluate()) {
              expect(
                (lens.renderObject as RenderBox).size.height,
                lessThan(800),
              );
            }
          }
          // The chat list carries the search field (ADR0087 §8). Its
          // navigation buttons inherit the root surface instead of creating
          // duplicate lens layers.
          expect(find.text('暂无角色'), findsOneWidget);
          expect(find.byType(TextField), findsOneWidget);
          final navigation = find.byType(CustomBottomNav);
          expect(find.descendant(of: navigation,
              matching: find.byType(MoeButtonSurface)), findsNothing);
          expect(find.descendant(of: navigation,
              matching: find.byType(MoeFloatingSurface)), findsNothing);
          // Besides the wide root pane, only the search field has its own glass.
          expect(
            find.byType(MoeLiquidGlass).evaluate().length,
            find
                    .descendant(
                      of: find.byType(MoeSearchField),
                      matching: find.byType(MoeLiquidGlass),
                    )
                    .evaluate()
                    .length +
                (width >= 900 ? 1 : 0),
          );
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

  for (final (enabled, liquid) in [(false, false), (true, false), (true, true)]) {
    testWidgets(
      'narrow root shows the global wallpaper without its own tint: '
      'enabled=$enabled liquid=$liquid',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 800);
        addTearDown(tester.view.reset);
        const style = WallpaperStyle(mask: 0.2, blur: 0);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              conversationsProvider.overrideWith(_EmptyConversations.new),
            ],
            child: MaterialApp(
              theme: ThemeData(extensions: [MoeColors.light()]),
              home: MoeWallpaperTheme(
                wallpaper: GlobalWallpaper.catnap,
                style: style,
                child: MoeGlassTheme(
                  enabled: enabled,
                  useLiquidGlass: liquid,
                  blurSigma: 16,
                  child: MoeWorkspace(
                    navigatorKey: GlobalKey<NavigatorState>(),
                    isWide: false,
                    isDetail: false,
                    child: const MainPage(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final wallpaper = find.byType(MoeGlobalWallpaper);
        expect(wallpaper, findsOneWidget);
        // The root adds no floating surface; only the search field has one.
        expect(
          find.byType(MoeFloatingSurface).evaluate().length,
          find
              .descendant(
                of: find.byType(MoeSearchField),
                matching: find.byType(MoeFloatingSurface),
              )
              .evaluate()
              .length,
        );
        // Only the wallpaper's own mask covers the image.
        final masks = tester
            .widgetList<ColoredBox>(
              find.descendant(of: wallpaper, matching: find.byType(ColoredBox)),
            )
            .where((box) => box.color.a > 0 && box.color.a < 1)
            .map((box) => box.color.a);
        expect(masks, isNotEmpty);
        expect(masks, everyElement(closeTo(style.mask, 0.01)));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
