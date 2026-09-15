import 'package:flutter/material.dart';

/// Decoration for inline fields and fields whose surface is painted by a parent.
/// Explicitly disables theme fill and borders in every interaction state.
class MoeInputDecoration extends InputDecoration {
  const MoeInputDecoration({
    super.hintText,
    super.hintStyle,
    super.contentPadding,
    super.isDense,
    super.prefixIcon,
    super.suffixIcon,
    super.counterText,
  }) : super(
         filled: false,
         border: InputBorder.none,
         enabledBorder: InputBorder.none,
         focusedBorder: InputBorder.none,
         disabledBorder: InputBorder.none,
         errorBorder: InputBorder.none,
         focusedErrorBorder: InputBorder.none,
       );
}
