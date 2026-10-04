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
abstract final class MoeFrostedMaterial {
  /// Heaviest blur. Flutter's popup recipe uses 30, which reads as opaque.
  static const double surfaceSigma = 20;

  static const double minStrength = 0.1;

  static const double _minTintOpacity = 0.42;
  static const double _maxTintOpacity = 0.72;

  // Dark containers are #1C1C1C over a pure black page.
  static const int _darkContainerLevel = 0x1C;

  static double blurSigmaForSetting(double sigma) =>
      surfaceSigma * (sigma / kMaxGlassBlurSigma).clamp(minStrength, 1.0);

  /// Tint for the global fill (0..1), set independently of the blur. Low
  /// fills read through like Apple's ultra-thin material.
  /// Below [minStrength] the tint fades linearly to fully clear at zero.
  static Color surfaceTint(Brightness brightness, {double fill = 1}) {
    final f = fill.clamp(0.0, 1.0);
    final opacity = f < minStrength
        ? _minTintOpacity * f / minStrength
        : _minTintOpacity +
              (_maxTintOpacity - _minTintOpacity) *
                  (f - minStrength) /
                  (1 - minStrength);
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

  static ui.ImageFilter surfaceFilter(
    Brightness brightness, {
    double sigma = surfaceSigma,
    TileMode? tileMode,
  }) {
    final blurSigma = sigma
        .clamp(surfaceSigma * minStrength, surfaceSigma)
        .toDouble();
    return ui.ImageFilter.compose(
      inner: ui.ColorFilter.matrix(
        brightness == Brightness.dark
            ? _darkSaturationMatrix
            : _lightSaturationMatrix,
      ),
      outer: ui.ImageFilter.blur(
        sigmaX: blurSigma,
        sigmaY: blurSigma,
        tileMode: tileMode,
      ),
    );
  }

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
