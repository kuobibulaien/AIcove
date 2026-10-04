import 'package:aicove_flutter/src/core/services/attachment_picker_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('merged attachment entry classifies picked files by extension', () {
    AttachmentType? typeOf(String ext) =>
        AttachmentPickerService.attachmentTypeForExtension(ext);

    expect(typeOf('md'), AttachmentType.file);
    expect(typeOf(''), AttachmentType.file);
    expect(typeOf('MP3'), AttachmentType.audio);
    expect(typeOf('m4a'), AttachmentType.audio);
    expect(typeOf('mov'), AttachmentType.video);
    expect(typeOf('png'), AttachmentType.image);
    expect(typeOf('heic'), AttachmentType.image);
    expect(typeOf('exe'), isNull);
    expect(typeOf('pdf'), isNull);
  });
}
