import 'package:aicove_flutter/src/ui/theme/moe_wallpaper.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WallpaperFraming.dragged', () {
    // A 2:1 image covering a 1:2 box: cover scale 2, rendered 400x200, so it
    // overflows 300 horizontally and not at all vertically.
    const box = Size(100, 200);
    const image = Size(200, 100);

    test('moves the focus against the drag by the overflow ratio', () {
      final moved = const WallpaperFraming().dragged(
        const Offset(-75, 40),
        box: box,
        image: image,
      );
      expect(moved.x, closeTo(0.5, 1e-9));
      // No vertical overflow: the vertical drag is ignored.
      expect(moved.y, 0);
    });

    test('zoom adds overflow on both axes', () {
      final moved = const WallpaperFraming(
        scale: 2,
      ).dragged(const Offset(0, -100), box: box, image: image);
      // Rendered height 400 at 2x, overflow 200.
      expect(moved.y, closeTo(1, 1e-9));
    });

    test('clamps to the image edges', () {
      final moved = const WallpaperFraming().dragged(
        const Offset(-10000, 0),
        box: box,
        image: image,
      );
      expect(moved.x, 1);
    });
  });

  group('WallpaperStyle framing per layout', () {
    const narrow = WallpaperFraming(x: -1, scale: 1.5);
    const wide = WallpaperFraming(y: 0.4);

    test('a layout without its own framing follows the other one', () {
      final style = const WallpaperStyle().withFraming(
        WallpaperLayout.narrow,
        narrow,
      );
      expect(style.framingFor(WallpaperLayout.narrow), narrow);
      expect(style.framingFor(WallpaperLayout.wide), narrow);
      expect(style.ownFraming(WallpaperLayout.wide), isNull);
    });

    test('falls back to the wallpaper default focus', () {
      expect(
        const WallpaperStyle().framingFor(
          WallpaperLayout.wide,
          fallback: Alignment.centerLeft,
        ),
        const WallpaperFraming(x: -1),
      );
    });

    test('own framings are independent and clearable', () {
      final style = const WallpaperStyle()
          .withFraming(WallpaperLayout.narrow, narrow)
          .withFraming(WallpaperLayout.wide, wide);
      expect(style.framingFor(WallpaperLayout.wide), wide);
      expect(
        style
            .withFraming(WallpaperLayout.wide, null)
            .framingFor(WallpaperLayout.wide),
        narrow,
      );
    });

    test('round-trips through settings JSON and the conversation column', () {
      final style = const WallpaperStyle(
        mask: 0.3,
        blur: 6,
      ).withFraming(WallpaperLayout.wide, wide);
      expect(WallpaperStyle.fromJson(style.toJson(), custom: false), style);
      expect(
        const WallpaperStyle(
          mask: 0.3,
          blur: 6,
        ).withEncodedFraming(style.encodedFraming),
        style,
      );
      expect(const WallpaperStyle().encodedFraming, isNull);
      expect(
        const WallpaperStyle().withEncodedFraming('not json'),
        const WallpaperStyle(),
      );
    });

    test('mask and blur edits keep the framings', () {
      final style = const WallpaperStyle().withFraming(
        WallpaperLayout.narrow,
        narrow,
      );
      expect(style.copyWith(mask: 0.5).narrow, narrow);
    });
  });
}
