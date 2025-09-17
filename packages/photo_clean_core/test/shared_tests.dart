import 'package:image/image.dart' as img;
import 'package:photo_clean_core/photo_clean_core.dart';
import 'package:test/test.dart';

void definePhotoCleanCoreTests() {
  test('pHash64 generates zero hash for a uniform image', () {
    final image = img.Image(width: 32, height: 32);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));

    final hash = pHash64(image);
    expect(hash.isNegative, isFalse);
    expect(hash.bitLength, lessThanOrEqualTo(64));
  });

  test('laplacianVariance captures contrast in an image', () {
    final image = img.Image(width: 5, height: 5);
    img.fill(image, color: img.ColorRgb8(0, 0, 0));
    image.setPixelRgba(2, 2, 255, 255, 255, 255);

    final variance = laplacianVariance(image);
    expect(variance, greaterThan(0));
  });

  test('clusterByPhash groups hashes within the threshold', () {
    final hashes = <BigInt>[
      BigInt.zero,
      BigInt.one,
      BigInt.from(0xff),
    ];

    final clusters = clusterByPhash(hashes, threshold: 1);
    final group = clusters.firstWhere((cluster) => cluster.contains(0));

    expect(group, containsAll(<int>[0, 1]));
    expect(group.length, 2);
  });
}
