import 'package:flutter/material.dart';

import '../shared/widgets/buttons/moe_button_surface.dart';
import 'tokens.dart';

/// Suppress pointer hover decoration while retaining press and keyboard feedback.
bool _hoverOnly(Set<WidgetState> states) =>
    states.contains(WidgetState.hovered) &&
    !states.contains(WidgetState.pressed) &&
    !states.contains(WidgetState.dragged) &&
    !states.contains(WidgetState.focused);

final moeInteractionOverlay = WidgetStateProperty.resolveWith<Color?>(
  (states) => _hoverOnly(states) ? Colors.transparent : null,
);

ButtonStyle withoutHoverFeedback(ButtonStyle style) {
  final materialStyle =
      style.backgroundColor == null || style.backgroundBuilder != null
      ? style
      : _withButtonMaterial(style);
  return materialStyle.copyWith(
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => _hoverOnly(states)
          ? Colors.transparent
          : style.overlayColor?.resolve(states),
    ),
    elevation: WidgetStateProperty.resolveWith(
      (states) =>
          materialStyle.elevation?.resolve(
            {...states}..remove(WidgetState.hovered),
          ) ??
          (_hoverOnly(states) ? 0 : null),
    ),
  );
}

ButtonStyle _withButtonMaterial(ButtonStyle style, {Color? tint}) =>
    style.copyWith(
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(0),
      backgroundBuilder: (context, states, child) {
        final widget = context.widget;
        final localStyle = widget is ButtonStyleButton ? widget.style : null;
        final shape =
            localStyle?.shape?.resolve(states) ?? style.shape?.resolve(states);
        final radius = switch (shape) {
          RoundedRectangleBorder(:final borderRadius) => borderRadius,
          RoundedSuperellipseBorder(:final borderRadius) => borderRadius,
          ContinuousRectangleBorder(:final borderRadius) => borderRadius,
          _ => BorderRadius.circular(999),
        };
        final side =
            localStyle?.side?.resolve(states) ?? style.side?.resolve(states);
        final disabled = states.contains(WidgetState.disabled);
        final colors = context.moeColors;
        final baseTint =
            style.backgroundColor?.resolve(states) ??
            (disabled
                ? colors.muted.withValues(alpha: 0.06)
                : (tint ??
                      (states.contains(WidgetState.selected)
                          ? colors.accentColor
                          : null)));
        final feedback =
            states.contains(WidgetState.pressed) ||
            states.contains(WidgetState.focused);
        return MoeButtonSurface(
          borderRadius: radius.resolve(Directionality.of(context)),
          border: states.contains(WidgetState.focused)
              ? Border.all(color: colors.accentColor)
              : (side == null ? null : Border.fromBorderSide(side)),
          tintColor: feedback
              ? Color.alphaBlend(
                  colors.text.withValues(alpha: 0.08),
                  baseTint ?? Colors.transparent,
                )
              : baseTint,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );

ThemeData withMoeInteractionTheme(ThemeData theme) {
  final colors =
      theme.extension<MoeColors>() ??
      (theme.brightness == Brightness.dark
          ? MoeColors.dark()
          : MoeColors.light());
  final buttons = withoutHoverFeedback(
    _withButtonMaterial(const ButtonStyle()),
  );
  final primaryButtons = withoutHoverFeedback(
    _withButtonMaterial(
      ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? colors.muted
              : colors.text,
        ),
      ),
      tint: colors.accentColor,
    ),
  );
  return theme.copyWith(
    hoverColor: Colors.transparent,
    iconButtonTheme: IconButtonThemeData(style: buttons),
    textButtonTheme: TextButtonThemeData(style: buttons),
    filledButtonTheme: FilledButtonThemeData(style: primaryButtons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
    elevatedButtonTheme: ElevatedButtonThemeData(style: primaryButtons),
    segmentedButtonTheme: SegmentedButtonThemeData(style: buttons),
    chipTheme: theme.chipTheme.copyWith(
      backgroundColor: Colors.transparent,
      disabledColor: Colors.transparent,
      selectedColor: colors.accentColor.withValues(alpha: 0.22),
      secondarySelectedColor: colors.accentColor.withValues(alpha: 0.22),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      pressElevation: 0,
    ),
    switchTheme: theme.switchTheme.copyWith(
      overlayColor: moeInteractionOverlay,
    ),
    checkboxTheme: theme.checkboxTheme.copyWith(
      overlayColor: moeInteractionOverlay,
    ),
    radioTheme: theme.radioTheme.copyWith(overlayColor: moeInteractionOverlay),
    sliderTheme: theme.sliderTheme.copyWith(
      overlayColor: WidgetStateColor.resolveWith(
        (states) => _hoverOnly(states)
            ? Colors.transparent
            : theme.colorScheme.primary.withValues(alpha: 0.12),
      ),
    ),
    floatingActionButtonTheme: theme.floatingActionButtonTheme.copyWith(
      hoverElevation: theme.floatingActionButtonTheme.elevation ?? 6,
      hoverColor: Colors.transparent,
    ),
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      hoverColor: Colors.transparent,
    ),
    tabBarTheme: theme.tabBarTheme.copyWith(
      overlayColor: moeInteractionOverlay,
    ),
  );
}
