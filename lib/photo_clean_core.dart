library photo_clean_core;

// Minimal core: pHash + blur variance + clustering + streaming events.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

BigInt pHash64(img.Image image, {int size = 32, int dctSize = 8}) {
  if (size <= 0 || dctSize <= 0 || dctSize > size) {
    throw ArgumentError('invalid size/dctSize');
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

int hamming64(BigInt a, BigInt b) {
  var value = a ^ b;
  var count = 0;
  while (value != BigInt.zero) {
    value &= (value - BigInt.one);
    count++;
  }
  return count;
}

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

  var sum = 0.0;
  for (final v in responses) sum += v;
  final mean = sum / responses.length;
  var sqSum = 0.0;
  for (final v in responses) {
    final diff = v - mean;
    sqSum += diff * diff;
  }
  return sqSum / responses.length;
}

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

// Streaming API

class InMemoryImageEntry {
  final String name;
  final Uint8List bytes;
  const InMemoryImageEntry(this.name, this.bytes);
}

abstract class StreamingAnalysisEvent { const StreamingAnalysisEvent(); }

class ImageAnalyzedEvent extends StreamingAnalysisEvent {
  final InMemoryImageEntry entry;
  final BigInt hash;
  final double blurVariance;
  final bool isBlurry;
  const ImageAnalyzedEvent({
    required this.entry,
    required this.hash,
    required this.blurVariance,
    required this.isBlurry,
  });
}

class ClustersUpdatedEvent extends StreamingAnalysisEvent {
  final List<List<InMemoryImageEntry>> similarGroups;
  const ClustersUpdatedEvent(this.similarGroups);
}

// New event: emits current aggregated cleanInfo map after each image analyzed.
class CleanInfoUpdatedEvent extends StreamingAnalysisEvent {
  final Map<String, dynamic> cleanInfo;
  const CleanInfoUpdatedEvent(this.cleanInfo);
}

Stream<StreamingAnalysisEvent> analyzeInMemoryStreaming(
  List<InMemoryImageEntry> entries, {
  int phashThreshold = 10,
  double blurThreshold = 250.0,
  int regroupEvery = 50,
}) async* {
  if (regroupEvery < 1) regroupEvery = 1;
  final hashes = <BigInt>[];
  final validEntries = <InMemoryImageEntry>[];
  final blurFlags = <bool>[]; // parallel list indicating blurry

  Map<String, dynamic> buildCleanInfo({List<List<InMemoryImageEntry>>? groupsCache}) {
    // Recompute groups if needed (only when requested after regroup or final)
    List<List<InMemoryImageEntry>> groups;
    if (groupsCache != null) {
      groups = groupsCache;
    } else {
      groups = _currentGroups(hashes, validEntries, phashThreshold);
    }

    // Determine duplicate/similar sets from groups (distance based)
    final duplicateNames = <String>{};
    final similarNames = <String>{};
    for (final g in groups) {
      // map name->index for hash access
      final idxList = g.map((e) => validEntries.indexOf(e)).where((i) => i >= 0).toList();
      for (var i = 0; i < idxList.length; i++) {
        for (var j = i + 1; j < idxList.length; j++) {
          final ia = idxList[i];
            final ib = idxList[j];
          final dist = hamming64(hashes[ia], hashes[ib]);
          if (dist == 0) {
            duplicateNames.add(validEntries[ia].name);
            duplicateNames.add(validEntries[ib].name);
          } else if (dist <= phashThreshold) {
            similarNames.add(validEntries[ia].name);
            similarNames.add(validEntries[ib].name);
          }
        }
      }
    }
    // remove duplicates from similar set
    similarNames.removeAll(duplicateNames);

    final blurNames = <String>{};
    for (var i = 0; i < validEntries.length; i++) {
      if (blurFlags[i]) blurNames.add(validEntries[i].name);
    }

    final allSize = validEntries.fold<int>(0, (p, e) => p + e.bytes.length);

    Map<String, dynamic> packSet(Set<String> names) {
      final list = validEntries.where((e) => names.contains(e.name)).toList();
      final size = list.fold<int>(0, (p, e) => p + e.bytes.length);
      return {
        'count': list.length,
        'size': size,
        'list': list.map((e) => e.name).toList(),
      };
    }

    final duplicateInfo = packSet(duplicateNames);
    final similarInfo = packSet(similarNames);
    final blurInfo = packSet(blurNames);
    final tagged = {...duplicateNames, ...similarNames, ...blurNames};
    final otherSet = validEntries.where((e) => !tagged.contains(e.name)).map((e) => e.name).toSet();
    final otherInfo = packSet(otherSet);

    return {
      'all': {
        'count': validEntries.length,
        'size': allSize,
        'list': validEntries.map((e) => e.name).toList(),
      },
      'duplicate': duplicateInfo,
      'similar': similarInfo,
      'blur': blurInfo,
      'screenshot': {'count': 0, 'size': 0, 'list': <String>[]}, // placeholder
      'video': {'count': 0, 'size': 0, 'list': <String>[]}, // placeholder
      'other': otherInfo,
    };
  }
  for (final e in entries) {
    try {
      final decoded = img.decodeImage(e.bytes);
      if (decoded == null) continue;
      final normalized = img.copyResize(
        decoded,
        width: 256,
        height: 256,
        interpolation: img.Interpolation.linear,
      );
      final h = pHash64(normalized);
      final bv = laplacianVariance(normalized);
      hashes.add(h);
      validEntries.add(e);
      blurFlags.add(bv < blurThreshold);
      yield ImageAnalyzedEvent(
        entry: e,
        hash: h,
        blurVariance: bv,
        isBlurry: bv < blurThreshold,
      );
      // After each image, emit cleanInfo snapshot (without forcing a fresh groups rebuild unless needed)
      // We pass null for groupsCache to allow grouping only at regroup steps.
      yield CleanInfoUpdatedEvent(buildCleanInfo());
      if (validEntries.length % regroupEvery == 0) {
        final groups = _currentGroups(hashes, validEntries, phashThreshold);
        yield ClustersUpdatedEvent(groups);
        // emit cleanInfo again to reflect refined duplicate/similar classification with fresh groups
        yield CleanInfoUpdatedEvent(buildCleanInfo(groupsCache: groups));
      }
    } catch (_) {}
  }
  if (validEntries.isNotEmpty) {
    final groups = _currentGroups(hashes, validEntries, phashThreshold);
    yield ClustersUpdatedEvent(groups);
    yield CleanInfoUpdatedEvent(buildCleanInfo(groupsCache: groups));
  }
}

List<List<InMemoryImageEntry>> _currentGroups(
  List<BigInt> hashes,
  List<InMemoryImageEntry> entries,
  int phashThreshold,
) {
  final clusters = clusterByPhash(hashes, threshold: phashThreshold);
  final out = <List<InMemoryImageEntry>>[];
  for (final c in clusters) {
    if (c.length > 1) {
      out.add(c.map((i) => entries[i]).toList());
    }
  }
  return out;
}

