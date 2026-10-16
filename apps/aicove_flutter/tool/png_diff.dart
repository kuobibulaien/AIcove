/// 逐像素比较两张同尺寸 PNG，输出差异统计，并可写出差异放大图。
/// dart run tool/png_diff.dart a.png b.png [diff.png]
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: png_diff.dart a.png b.png [diff.png]');
    exit(64);
  }
  final a = img.decodePng(File(args[0]).readAsBytesSync())!;
  final b = img.decodePng(File(args[1]).readAsBytesSync())!;
  if (a.width != b.width || a.height != b.height) {
    stdout.writeln(
      'size differs: ${a.width}x${a.height} vs ${b.width}x${b.height}',
    );
    exit(1);
  }
  final diff = img.Image(width: a.width, height: a.height);
  var changed = 0;
  var over2 = 0;
  var maxDelta = 0;
  var sum = 0;
  int? top, bottom, left, right;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final pa = a.getPixel(x, y);
      final pb = b.getPixel(x, y);
      final delta = [
        (pa.r - pb.r).abs(),
        (pa.g - pb.g).abs(),
        (pa.b - pb.b).abs(),
        (pa.a - pb.a).abs(),
      ].reduce(math.max).toInt();
      if (delta > 0) {
        changed++;
        sum += delta;
        if (delta > 2) over2++;
        maxDelta = math.max(maxDelta, delta);
        top = math.min(top ?? y, y);
        bottom = math.max(bottom ?? y, y);
        left = math.min(left ?? x, x);
        right = math.max(right ?? x, x);
      }
      final v = math.min(255, delta * 16);
      diff.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  final total = a.width * a.height;
  stdout.writeln(
    'pixels=$total changed=$changed (${(changed * 100 / total).toStringAsFixed(3)}%) '
    'over2=$over2 maxDelta=$maxDelta meanDeltaOfChanged='
    '${changed == 0 ? 0 : (sum / changed).toStringAsFixed(2)} '
    'bbox=${changed == 0 ? '-' : '[$left,$top]-[$right,$bottom]'}',
  );
  if (args.length > 2) File(args[2]).writeAsBytesSync(img.encodePng(diff));
}
