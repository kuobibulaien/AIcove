import 'package:flutter/material.dart';
import '../../../../core/theme/tokens.dart';
import 'package:mygril_flutter/src/core/utils/data_image.dart';

/// MoeTalk 风格的角色立绘展示组件
class CharacterDisplay extends StatelessWidget {
  final String? characterImage;
  final String displayName;
  final String? organization;

  const CharacterDisplay({
    super.key,
    this.characterImage,
    required this.displayName,
    this.organization,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 280,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            moeHeaderGradientStart.withAlpha(25),
            moePanel,
          ],
        ),
      ),
      child: Stack(
        children: [
          // 装饰背景
          Positioned(
            top: 0,
            right: 0,
            child: Opacity(
              opacity: 0.15,
              child: Image.asset(
                'assets/ui/hexa_back_01.webp',
                width: 200,
                height: 200,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox(),
              ),
            ),
          ),
          // 角色立绘
          if (characterImage != null)
            Positioned(
              bottom: 0,
              right: 20,
              child: _buildCharacterImage(characterImage!),
            ),
          // 角色信息
          Positioned(
            left: 20,
            bottom: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (organization != null && organization!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: moePrimary.withAlpha(51),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: moePrimary.withAlpha(76)),
                    ),
                    child: Text(
                      organization!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: moePrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  displayName,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: moeText,
                    shadows: [
                      Shadow(
                        color: Colors.white,
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _buildCharacterImage(String value) {
  final bytes = decodeDataImage(value);
  if (bytes != null) {
    return Image.memory(
      bytes,
      height: 240,
      fit: BoxFit.contain,
    );
  }
  return Image.asset(
    value,
    height: 240,
    fit: BoxFit.contain,
    errorBuilder: (context, error, stackTrace) {
      return Container(
        height: 240,
        width: 160,
        alignment: Alignment.center,
        child: Icon(
          Icons.person_outline,
          size: 100,
          color: moeMuted,
        ),
      );
    },
  );
}
