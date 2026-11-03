// Copyright 2014 The Flutter Authors. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
//       copyright notice, this list of conditions and the following
//       disclaimer in the documentation and/or other materials provided
//       with the distribution.
//     * Neither the name of Google Inc. nor the names of its
//       contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
// ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';

import 'tokens.dart';

/// Pre-Liquid-Glass Cupertino material, tuned toward Apple's thin bar
/// materials instead of the thick alert popup. Saturation matrices are copied
/// from Flutter's dialog.dart; blur range and tint opacity are AIcove's.
/// These are approximations, not Apple's unpublished UIKit filter internals.
///
/// The 50% setting of both sliders is the recommended, iOS-closest step:
/// blur sigma 10 as Flutter's CupertinoNavigationBar, the full saturation
/// matrix, and a thin-material tint. Below it the matrix and tint fade out
/// together, so a zero fill leaves a pure blur with no colour cast.
abstract final class MoeFrostedMaterial {
  /// Heaviest blur. Flutter's popup recipe uses 30, which reads as opaque.
  static const double surfaceSigma = 20;

  /// Fill at which the material matches the iOS reference.
  static const double recommendedFill = 0.5;

  static const double _recommendedTintOpacity = 0.55;
  static const double _maxTintOpacity = 0.72;

  // Dark containers are #1C1C1C over a pure black page.
  static const int _darkContainerLevel = 0x1C;

  static double blurSigmaForSetting(double sigma) =>
      surfaceSigma * (sigma / kMaxGlassBlurSigma).clamp(0.0, 1.0);

  /// Tint for the global fill (0..1), set independently of the blur.
  /// Zero is fully clear, [recommendedFill] lands on the thin material and
  /// the top end thickens toward, but stays below, the popup opacity.
  static Color surfaceTint(Brightness brightness, {double fill = 1}) {
    final f = fill.clamp(0.0, 1.0);
    final opacity = f <= recommendedFill
        ? _recommendedTintOpacity * f / recommendedFill
        : _recommendedTintOpacity +
              (_maxTintOpacity - _recommendedTintOpacity) *
                  (f - recommendedFill) /
                  (1 - recommendedFill);
    final alpha = (255 * opacity).round();
    if (brightness == Brightness.light) {
      return Color.fromARGB(alpha, 0xF8, 0xF8, 0xF8);
    }
    if (alpha == 0) return const Color(0x00000000);
    // Derived so the tint over the black page equals the solid container;
    // very thin fills cap at white and read slightly darker than it.
    final level = (_darkContainerLevel * 255 / alpha).round().clamp(0, 255);
    return Color.fromARGB(alpha, level, level, level);
  }

  /// Share of the saturation matrix applied at [fill]: none at zero, full
  /// from [recommendedFill] up.
  static double saturationAmount(double fill) =>
      (fill / recommendedFill).clamp(0.0, 1.0);

  /// Evaluates the saturation matrix of [surfaceFilter] on a uniform [backdrop]
  /// color. Blurring a uniform opaque surface is an identity operation, so the
  /// filtered backdrop equals this constant color at every pixel.
  static Color saturateColor(
    Brightness brightness,
    Color backdrop, {
    double fill = 1,
  }) {
    final amount = saturationAmount(fill);
    if (amount == 0) return backdrop;
    final target = brightness == Brightness.dark
        ? _darkSaturationMatrix
        : _lightSaturationMatrix;
    final r = backdrop.r * 255.0;
    final g = backdrop.g * 255.0;
    final b = backdrop.b * 255.0;
    final a = backdrop.a * 255.0;
    int channel(int row) {
      final base = row * 5;
      double m(int col) =>
          _identityMatrix[base + col] +
          (target[base + col] - _identityMatrix[base + col]) * amount;
      return (m(0) * r + m(1) * g + m(2) * b + m(3) * a + m(4)).round().clamp(
        0,
        255,
      );
    }

    return Color.fromARGB(
      channel(3),
      channel(0),
      channel(1),
      channel(2),
    );
  }

  static ui.ImageFilter surfaceFilter(
    Brightness brightness, {
    double sigma = surfaceSigma,
    double fill = 1,
    TileMode? tileMode,
  }) {
    final blurSigma = sigma.clamp(0.0, surfaceSigma).toDouble();
    final blur = ui.ImageFilter.blur(
      sigmaX: blurSigma,
      sigmaY: blurSigma,
      tileMode: tileMode,
    );
    final amount = saturationAmount(fill);
    if (amount == 0) return blur;
    final target = brightness == Brightness.dark
        ? _darkSaturationMatrix
        : _lightSaturationMatrix;
    return ui.ImageFilter.compose(
      inner: ui.ColorFilter.matrix(<double>[
        for (var i = 0; i < 20; i++)
          _identityMatrix[i] + (target[i] - _identityMatrix[i]) * amount,
      ]),
      outer: blur,
    );
  }

  static const List<double> _identityMatrix = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  static const List<double> _lightSaturationMatrix = <double>[
    1.74,
    -0.40,
    -0.17,
    0.00,
    0.00,
    -0.26,
    1.60,
    -0.17,
    0.00,
    0.00,
    -0.26,
    -0.40,
    1.83,
    0.00,
    0.00,
    0.00,
    0.00,
    0.00,
    1.00,
    0.00,
  ];

  static const List<double> _darkSaturationMatrix = <double>[
    1.39,
    -0.56,
    -0.11,
    0.00,
    0.30,
    -0.32,
    1.14,
    -0.11,
    0.00,
    0.30,
    -0.32,
    -0.56,
    1.59,
    0.00,
    0.30,
    0.00,
    0.00,
    0.00,
    1.00,
    0.00,
  ];
}

/// Declares that the backdrop directly behind [child] is a uniform opaque
/// [color] with no wallpaper or intermediate scrolling content.
///
/// Content cards and resting controls inside this scope can evaluate their
/// material tint against [color] directly instead of scheduling a per-frame
/// GPU backdrop blur over a flat solid color.
class MoeSolidBackdropScope extends StatefulWidget {
  const MoeSolidBackdropScope({
    super.key,
    required this.color,
    required this.child,
    this.waitForRouteTransition = false,
  });

  const MoeSolidBackdropScope.none({
    super.key,
    required this.child,
  }) : color = null,
       waitForRouteTransition = false;

  final Color? color;
  final Widget child;

  /// When true (wide-screen detail panes whose background is hoisted to the
  /// workspace shell after a post-frame callback), withholds [color] while the
  /// enclosing route is animating or before its background registration frame.
  final bool waitForRouteTransition;

  static Color? colorOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_SolidBackdropInherited>()
      ?.color;

  @override
  State<MoeSolidBackdropScope> createState() => _MoeSolidBackdropScopeState();
}

class _MoeSolidBackdropScopeState extends State<MoeSolidBackdropScope> {
  Animation<double>? _primary;
  Animation<double>? _secondary;
  bool _postFrameReady = false;

  @override
  void initState() {
    super.initState();
    _schedulePostFrameIfNeeded();
  }

  @override
  void didUpdateWidget(MoeSolidBackdropScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.waitForRouteTransition && !oldWidget.waitForRouteTransition) {
      _postFrameReady = false;
      _schedulePostFrameIfNeeded();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindRouteAnimations();
  }

  void _schedulePostFrameIfNeeded() {
    if (!widget.waitForRouteTransition) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_postFrameReady) {
        setState(() => _postFrameReady = true);
      }
    });
  }

  void _bindRouteAnimations() {
    _primary?.removeStatusListener(_onAnimationStatus);
    _secondary?.removeStatusListener(_onAnimationStatus);
    if (!widget.waitForRouteTransition) {
      _primary = null;
      _secondary = null;
      return;
    }
    final route = ModalRoute.of(context);
    _primary = route?.animation;
    _secondary = route?.secondaryAnimation;
    _primary?.addStatusListener(_onAnimationStatus);
    _secondary?.addStatusListener(_onAnimationStatus);
  }

  void _onAnimationStatus(AnimationStatus _) {
    if (mounted) setState(() {});
  }

  bool get _isRouteSettled {
    if (!widget.waitForRouteTransition) return true;
    if (!_postFrameReady) return false;
    final primaryOk =
        _primary == null || _primary!.status == AnimationStatus.completed;
    final secondaryOk =
        _secondary == null || _secondary!.status == AnimationStatus.dismissed;
    return primaryOk && secondaryOk;
  }

  @override
  void dispose() {
    _primary?.removeStatusListener(_onAnimationStatus);
    _secondary?.removeStatusListener(_onAnimationStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final effectiveColor =
        (c != null && c.a >= 1.0 && _isRouteSettled) ? c : null;
    return _SolidBackdropInherited(
      color: effectiveColor,
      child: widget.child,
    );
  }
}

class _SolidBackdropInherited extends InheritedWidget {
  const _SolidBackdropInherited({
    required this.color,
    required super.child,
  });

  final Color? color;

  @override
  bool updateShouldNotify(_SolidBackdropInherited oldWidget) =>
      oldWidget.color != color;
}
