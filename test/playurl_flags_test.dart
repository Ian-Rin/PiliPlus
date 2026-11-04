import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('episode playurl flags that keep thread-ripper off', () {
    final plain = PlayUrlModel.fromJson({});
    expect((plain.isDrm, plain.isPreview), (false, false));
    final drm = PlayUrlModel.fromJson({'is_drm': true, 'is_preview': 0});
    expect((drm.isDrm, drm.isPreview), (true, false));
    final preview = PlayUrlModel.fromJson({'is_drm': false, 'is_preview': 1});
    expect((preview.isDrm, preview.isPreview), (false, true));
  });
}
