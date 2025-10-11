import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:photo_clean_core/photo_clean_core.dart';
import 'package:test/test.dart';

void main() {
  img.Image pattern(int seed) {
    final im = img.Image(width: 40, height: 40);
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final v = (x * seed + y * 3) % 255;
        im.setPixelRgba(x, y, v, (v * 2) % 255, (v * 3) % 255, 255);
      }
    }
    return im;
  }

  test('streaming analysis emits only cleanInfo batch events at regroup points', () async {
    final a = pattern(5);
    final b = img.copyRotate(a, angle: 0);
    final c = pattern(11);

    final entries = [
      InMemoryImageEntry('a', Uint8List.fromList(img.encodePng(a))),
      InMemoryImageEntry('b', Uint8List.fromList(img.encodePng(b))),
      InMemoryImageEntry('c', Uint8List.fromList(img.encodePng(c))),
    ];

    final cleanInfoEvents = <CleanInfoUpdatedEvent>[];
    await for (final ev in analyzeInMemoryStreaming(entries, phashThreshold: 5, regroupEvery: 1)) {
      if (ev is CleanInfoUpdatedEvent) cleanInfoEvents.add(ev);
    }

    // regroupEvery=1 -> one batch per image (no extra final flush)
    expect(cleanInfoEvents.length, equals(entries.length));

    final lastInfo = cleanInfoEvents.last.cleanInfo;
    expect(lastInfo.containsKey('all'), isTrue);
    expect(lastInfo['all']['count'], 3);
    // categories exist
    for (final k in ['duplicate','similar','blur','other','screenshot','video']) {
      expect(lastInfo.containsKey(k), isTrue, reason: 'missing category $k');
    }
    // a 与 b 应该在 duplicate 或 similar 分类里之一（相同图像）
    final dupList = (lastInfo['duplicate']['list'] as List).cast<String>();
    final simList = (lastInfo['similar']['list'] as List).cast<String>();
    final together = (dupList.contains('a') && dupList.contains('b')) ||
        (simList.contains('a') && simList.contains('b'));
    expect(together, isTrue, reason: 'a & b 应该被识别为重复或相似');
  });
}
