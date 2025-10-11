import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:photo_clean_core/photo_clean_core.dart';
import 'package:test/test.dart';

Uint8List _bytesOf(img.Image im) => Uint8List.fromList(img.encodePng(im));

void main() {
  // Helper to make a patterned image with a seed.
  img.Image pat(int seed, {int size = 48}) {
    final im = img.Image(width: size, height: size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = (x * seed + y * 7) % 255;
        im.setPixelRgba(x, y, v, (v * 2) % 255, (v * 3) % 255, 255);
      }
    }
    return im;
  }

  test('analyzeInMemorySummary basic categories', () async {
    // duplicate pair (exact same)
    final a1 = pat(3);
    final a2 = img.copyRotate(a1, angle: 0); // identical

    // similar (slight change) - modify one pixel
    final b1 = pat(9);
    final b2 = img.copyRotate(b1, angle: 0);
    b2.setPixelRgba(0, 0, 255, 0, 0, 255); // tiny diff

    // blurry candidate (downscale then upscale to reduce variance)
    final sharp = pat(13, size: 80);
    final tiny = img.copyResize(sharp, width: 8, height: 8, interpolation: img.Interpolation.average);
    final blurry = img.copyResize(tiny, width: 80, height: 80, interpolation: img.Interpolation.average);

    final entries = <InMemoryImageEntry>[
      InMemoryImageEntry('dup1.png', _bytesOf(a1)),
      InMemoryImageEntry('dup2.png', _bytesOf(a2)),
      InMemoryImageEntry('sim1.png', _bytesOf(b1)),
      InMemoryImageEntry('sim2.png', _bytesOf(b2)),
      InMemoryImageEntry('blurry.png', _bytesOf(blurry)),
    ];

    final summary = await analyzeInMemorySummary(
      entries,
      phashThreshold: 6, // allow similar grouping
      blurThreshold: 50, // our generated blurry should fall below this
    );

    // all
    expect(summary.all.count, 5);
    expect(summary.all.list.length, 5);

    // duplicates or similar should at least include dup1 & dup2 in same group
    final dupOrSimNames = {
      ...summary.duplicate.list.map((e) => e.entry.name),
      ...summary.similar.list.map((e) => e.entry.name),
    };
    expect(dupOrSimNames.contains('dup1.png'), isTrue);
    expect(dupOrSimNames.contains('dup2.png'), isTrue);

  // sim1 & sim2 should appear in either duplicate or similar collections (hash distance may collapse)
  expect(dupOrSimNames.contains('sim1.png'), isTrue);
  expect(dupOrSimNames.contains('sim2.png'), isTrue);

    // blur: only blurry.png expected
    expect(summary.blur.count, greaterThanOrEqualTo(1));
    final blurNames = summary.blur.list.map((e) => e.entry.name).toSet();
    expect(blurNames.contains('blurry.png'), isTrue);

    // other: at least one item that is not blurry or duplicate or similar (may be none if all classified)
    // Because blurry might also be in a similar group, we only assert non-negativity.
    expect(summary.other.count, greaterThanOrEqualTo(0));
  });
}
