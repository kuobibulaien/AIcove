import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_icon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ColorFlipHarness extends StatefulWidget {
  const _ColorFlipHarness({super.key});

  @override
  State<_ColorFlipHarness> createState() => _ColorFlipHarnessState();
}

class _ColorFlipHarnessState extends State<_ColorFlipHarness> {
  Color _color = Colors.red;

  void setColor(Color value) {
    if (!mounted) return;
    setState(() => _color = value);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: MoeIconButton(
        icon: Icons.delete_outline,
        color: _color,
        onTap: () {},
      ),
    );
  }
}

void main() {
  testWidgets('MoeIconButton rapid color changes should not throw duplicate key',
      (tester) async {
    final hostKey = GlobalKey<_ColorFlipHarnessState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _ColorFlipHarness(key: hostKey),
        ),
      ),
    );

    for (var i = 0; i < 6; i++) {
      hostKey.currentState!.setColor(Colors.blue);
      await tester.pump(const Duration(milliseconds: 8));
      hostKey.currentState!.setColor(Colors.red);
      await tester.pump(const Duration(milliseconds: 8));
    }

    await tester.pump(const Duration(milliseconds: 20));

    Object? firstException;
    while (true) {
      final error = tester.takeException();
      if (error == null) break;
      firstException ??= error;
    }

    expect(
      firstException,
      isNull,
      reason: '快速切换图标颜色时不应出现 Duplicate key 报错',
    );
  });
}
