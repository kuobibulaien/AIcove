import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../shared/widgets/index.dart';

/// Live camera scan for a LAN pairing code; pops with the scanned code.
class LanScanPage extends StatefulWidget {
  const LanScanPage({super.key});

  static bool get supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  State<LanScanPage> createState() => _LanScanPageState();
}

class _LanScanPageState extends State<LanScanPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    // Macs only have a front camera.
    facing: Platform.isMacOS ? CameraFacing.front : CameraFacing.back,
  );
  bool _done = false, _foreign = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      if (value.startsWith('aicove-lan:')) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
      if (!_foreign) setState(() => _foreign = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MoePageScaffold(
      appBar: const MoeAppBar(title: '扫一扫', showBackButton: true),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _detect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? '没有相机权限，请在系统设置里允许 AIcove 使用相机，或改用数字配对码'
                      : '相机暂不可用，请改用数字配对码或导入二维码',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              _foreign ? '这不是 AIcove 的配对二维码' : '对准另一台设备上的配对二维码',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                shadows: [Shadow(blurRadius: 6)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
