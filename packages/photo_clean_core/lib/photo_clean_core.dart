library photo_clean_core;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:image/image.dart' as img;

/// Generate a 64-bit perceptual hash for the provided [img.Image].
///
/// The algorithm downsamples the image to [size]×[size], converts it to
/// grayscale, performs a 2D DCT-II and then looks at the top-left [dctSize]×
/// [dctSize] coefficients. The DC coefficient (0,0) is excluded from the
/// threshold calculation but still contributes a bit so the returned hash has
/// `[dctSize] * [dctSize]` bits (64 when `dctSize == 8`).
BigInt pHash64(img.Image image, {int size = 32, int dctSize = 8}) {
  if (size <= 0) {
    throw ArgumentError.value(size, 'size', 'Size must be positive');
  }
  if (dctSize <= 0) {
    throw ArgumentError.value(dctSize, 'dctSize', 'dctSize must be positive');
  }
  if (dctSize > size) {
    throw ArgumentError.value(
      dctSize,
      'dctSize',
      'dctSize must be smaller than or equal to the resize size',
    );
  }

  final resized = img.copyResize(
    image,
    width: size,
    height: size,
    interpolation: img.Interpolation.linear,
  );
  final grayscale = img.grayscale(resized);

  final pixels = List.generate(
    size,
    (y) => List<double>.filled(size, 0.0, growable: false),
    growable: false,
  );
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final pixel = grayscale.getPixel(x, y);
      pixels[y][x] = pixel.luminance.toDouble();
    }
  }

  final dct = _dct2D(pixels);
  final coefficients = <double>[];
  for (var v = 0; v < dctSize; v++) {
    for (var u = 0; u < dctSize; u++) {
      coefficients.add(dct[v][u]);
    }
  }

  if (coefficients.isEmpty) {
    return BigInt.zero;
  }

  final valuesWithoutDc =
      coefficients.length > 1 ? coefficients.sublist(1) : coefficients;
  final threshold = _median(valuesWithoutDc);

  BigInt hash = BigInt.zero;
  for (var i = 0; i < coefficients.length; i++) {
    hash <<= 1;
    if (i == 0) {
      continue; // Skip the DC component bit.
    }
    if (coefficients[i] > threshold) {
      hash |= BigInt.one;
    }
  }
  return hash;
}

/// Compute the Hamming distance between two 64-bit perceptual hashes.
int hamming64(BigInt a, BigInt b) {
  var value = a ^ b;
  var count = 0;
  while (value != BigInt.zero) {
    value &= (value - BigInt.one);
    count++;
  }
  return count;
}

/// Compute the Laplacian variance on a grayscale version of [image].
///
/// The image is converted to grayscale (if necessary) before applying the
/// 3×3 Laplacian kernel `[0, 1, 0; 1, -4, 1; 0, 1, 0]`. The variance of the
/// filter response is returned — a larger value indicates a sharper image.
double laplacianVariance(img.Image image) {
  final grayscale = image.numChannels == 1 ? image : img.grayscale(image);
  if (grayscale.width < 3 || grayscale.height < 3) {
    return 0.0;
  }

  final responses = <double>[];
  for (var y = 1; y < grayscale.height - 1; y++) {
    for (var x = 1; x < grayscale.width - 1; x++) {
      final value = _luminance(grayscale, x, y - 1) +
          _luminance(grayscale, x - 1, y) +
          _luminance(grayscale, x + 1, y) +
          _luminance(grayscale, x, y + 1) -
          4 * _luminance(grayscale, x, y);
      responses.add(value);
    }
  }

  if (responses.isEmpty) {
    return 0.0;
  }

  final mean = responses.sum / responses.length;
  final variance = responses.map((value) {
        final diff = value - mean;
        return diff * diff;
      }).sum /
      responses.length;
  return variance;
}

/// Group image hashes by Hamming distance using a simple union-find clusterer.
List<List<int>> clusterByPhash(List<BigInt> hashes, {int threshold = 10}) {
  if (hashes.isEmpty) {
    return <List<int>>[];
  }

  final parent = List<int>.generate(hashes.length, (index) => index);

  int find(int index) {
    if (parent[index] != index) {
      parent[index] = find(parent[index]);
    }
    return parent[index];
  }

  void union(int a, int b) {
    final rootA = find(a);
    final rootB = find(b);
    if (rootA == rootB) {
      return;
    }
    parent[rootB] = rootA;
  }

  for (var i = 0; i < hashes.length; i++) {
    for (var j = i + 1; j < hashes.length; j++) {
      if (hamming64(hashes[i], hashes[j]) <= threshold) {
        union(i, j);
      }
    }
  }

  final clusters = <int, List<int>>{};
  for (var i = 0; i < hashes.length; i++) {
    final root = find(i);
    clusters.putIfAbsent(root, () => <int>[]).add(i);
  }

  final result = clusters.values.map((cluster) => (cluster..sort())).toList()
    ..sort((a, b) => a.first.compareTo(b.first));
  return result;
}

/// Compute similarity percent (0.0 - 100.0) between two 64-bit phashes.
/// Convenience wrapper around `hamming64`.
double similarityPercentFromHashes(BigInt a, BigInt b) {
  final hd = hamming64(a, b);
  return ((64 - hd) / 64.0) * 100.0;
}

/// Compute pHash for raw image bytes. Returns `BigInt.zero` if decoding fails.
BigInt pHash64FromBytes(Uint8List bytes, {int size = 32, int dctSize = 8}) {
  final image = img.decodeImage(bytes);
  if (image == null) return BigInt.zero;
  return pHash64(image, size: size, dctSize: dctSize);
}

/// Compute Laplacian variance for raw image bytes. Returns 0.0 on decode failure.
double laplacianVarianceFromBytes(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) return 0.0;
  return laplacianVariance(image);
}

/// Compute similarity percent directly from two byte buffers (images).
/// Returns 0.0 if either image cannot be decoded.
double similarityPercentFromBytes(Uint8List a, Uint8List b,
    {int size = 32, int dctSize = 8}) {
  final ia = img.decodeImage(a);
  final ib = img.decodeImage(b);
  if (ia == null || ib == null) return 0.0;
  final ha = pHash64(ia, size: size, dctSize: dctSize);
  final hb = pHash64(ib, size: size, dctSize: dctSize);
  return similarityPercentFromHashes(ha, hb);
}

/// Convenience boolean check: is this image blurry under [threshold]?
/// Returns `true` if variance < threshold (i.e. potentially blurry).
bool isBlurryFromBytes(Uint8List bytes, double threshold) {
  final v = laplacianVarianceFromBytes(bytes);
  return v < threshold;
}

/// Same helpers but accepting decoded `img.Image` directly.
double similarityPercentFromImage(img.Image a, img.Image b) {
  final ha = pHash64(a);
  final hb = pHash64(b);
  return similarityPercentFromHashes(ha, hb);
}

double laplacianVarianceFromImage(img.Image image) => laplacianVariance(image);

bool isBlurryFromImage(img.Image image, double threshold) => laplacianVariance(image) < threshold;

double _luminance(img.Image image, int x, int y) {
  final pixel = image.getPixel(x, y);
  return pixel.luminance.toDouble();
}

List<List<double>> _dct2D(List<List<double>> input) {
  final size = input.length;
  final output = List.generate(
    size,
    (_) => List<double>.filled(size, 0.0, growable: false),
    growable: false,
  );

  final factor = math.pi / (2.0 * size);
  final cosTableX = List.generate(
    size,
    (u) => List<double>.generate(
        size, (x) => math.cos((2 * x + 1) * u * factor),
        growable: false),
    growable: false,
  );
  final cosTableY = List.generate(
    size,
    (v) => List<double>.generate(
        size, (y) => math.cos((2 * y + 1) * v * factor),
        growable: false),
    growable: false,
  );

  final scale0 = math.sqrt(1.0 / size);
  final scale = math.sqrt(2.0 / size);

  for (var v = 0; v < size; v++) {
    for (var u = 0; u < size; u++) {
      var sum = 0.0;
      for (var y = 0; y < size; y++) {
        final row = input[y];
        final cosY = cosTableY[v][y];
        for (var x = 0; x < size; x++) {
          sum += row[x] * cosTableX[u][x] * cosY;
        }
      }
      final alphaU = u == 0 ? scale0 : scale;
      final alphaV = v == 0 ? scale0 : scale;
      output[v][u] = alphaU * alphaV * sum;
    }
  }

  return output;
}

double _median(List<double> values) {
  if (values.isEmpty) {
    return 0.0;
  }
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) {
    return sorted[mid];
  }
  return (sorted[mid - 1] + sorted[mid]) / 2.0;
}

String phashHex(BigInt v) {
  final hex = v.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  return '0x$hex';
}
