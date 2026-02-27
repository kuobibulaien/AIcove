import 'package:flutter/material.dart';

import 'expanding_page_route.dart';

/// Keeps Hero rect interpolation aligned with ExpandingPageRoute's curve.
RectTween createExpandingAlignedHeroRectTween(Rect? begin, Rect? end) {
  return _CurvedRectTween(
    begin: begin,
    end: end,
    curve: kExpandingPageTransitionCurve,
  );
}

class _CurvedRectTween extends RectTween {
  _CurvedRectTween({
    required super.begin,
    required super.end,
    required this.curve,
  });

  final Curve curve;

  @override
  Rect? lerp(double t) {
    final clampedT = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
    return Rect.lerp(begin, end, curve.transform(clampedT));
  }
}
