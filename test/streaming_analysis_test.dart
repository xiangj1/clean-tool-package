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

  test('streaming analysis emits image, cleanInfo and cluster events', () async {
    final a = pattern(5);
    final b = img.copyRotate(a, angle: 0);
    final c = pattern(11);

    final entries = [
      InMemoryImageEntry('a', Uint8List.fromList(img.encodePng(a))),
      InMemoryImageEntry('b', Uint8List.fromList(img.encodePng(b))),
      InMemoryImageEntry('c', Uint8List.fromList(img.encodePng(c))),
    ];

    final events = <StreamingAnalysisEvent>[];
    await for (final ev in analyzeInMemoryStreaming(entries, phashThreshold: 5, regroupEvery: 1)) {
      events.add(ev);
    }

    final clusterEvents = events.whereType<ClustersUpdatedEvent>().toList();
    final cleanInfoEvents = events.whereType<CleanInfoUpdatedEvent>().toList();
    expect(clusterEvents, isNotEmpty);
    expect(cleanInfoEvents.length, greaterThanOrEqualTo(entries.length),
        reason: 'Should emit at least one cleanInfo per processed image');

    // Inspect last cleanInfo snapshot
    final lastInfo = cleanInfoEvents.last.cleanInfo;
    expect(lastInfo.containsKey('all'), isTrue);
    expect(lastInfo['all']['count'], 3);
    // categories exist
    for (final k in ['duplicate','similar','blur','other','screenshot','video']) {
      expect(lastInfo.containsKey(k), isTrue, reason: 'missing category $k');
    }
    final hasAB = clusterEvents.any((ce) =>
        ce.similarGroups.any((g) => g.any((e) => e.name == 'a') && g.any((e) => e.name == 'b')));
    expect(hasAB, isTrue);
  });
}
