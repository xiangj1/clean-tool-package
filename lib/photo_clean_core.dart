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

Stream<StreamingAnalysisEvent> analyzeInMemoryStreaming(
  List<InMemoryImageEntry> entries, {
  int phashThreshold = 10,
  double blurThreshold = 250.0,
  int regroupEvery = 50,
}) async* {
  if (regroupEvery < 1) regroupEvery = 1;
  final hashes = <BigInt>[];
  final validEntries = <InMemoryImageEntry>[];
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
      yield ImageAnalyzedEvent(
        entry: e,
        hash: h,
        blurVariance: bv,
        isBlurry: bv < blurThreshold,
      );
      if (validEntries.length % regroupEvery == 0) {
        yield ClustersUpdatedEvent(_currentGroups(hashes, validEntries, phashThreshold));
      }
    } catch (_) {}
  }
  if (validEntries.isNotEmpty) {
    yield ClustersUpdatedEvent(_currentGroups(hashes, validEntries, phashThreshold));
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

// ------------------------------------------------------------
// Batch summary API (non-stream) — categories: all / duplicate / similar / blur / other
// ------------------------------------------------------------

class ImageAnalysisItem {
  final InMemoryImageEntry entry;
  final BigInt hash;
  final double blurVariance;
  final bool isBlurry;
  // groupId is optional: assigned after grouping; groups with single element get -1.
  final int groupId;
  const ImageAnalysisItem({
    required this.entry,
    required this.hash,
    required this.blurVariance,
    required this.isBlurry,
    required this.groupId,
  });
}

class CleanCategorySummary {
  final int count;
  final int size; // total bytes
  final List<ImageAnalysisItem> list;
  const CleanCategorySummary({required this.count, required this.size, required this.list});
}

class CleanAnalysisSummary {
  final CleanCategorySummary all;
  final CleanCategorySummary duplicate;
  final CleanCategorySummary similar;
  final CleanCategorySummary blur;
  final CleanCategorySummary other;
  // groups: only groups with length > 1 (duplicates and/or similars)
  final List<List<ImageAnalysisItem>> groups;
  const CleanAnalysisSummary({
    required this.all,
    required this.duplicate,
    required this.similar,
    required this.blur,
    required this.other,
    required this.groups,
  });

  Map<String, dynamic> toMap() => {
        'all': _catMap(all),
        'duplicate': _catMap(duplicate),
        'similar': _catMap(similar),
        'blur': _catMap(blur),
        'other': _catMap(other),
        'groups': groups
            .map((g) => g
                .map((i) => {
                      'name': i.entry.name,
                      'hash': i.hash.toUnsigned(64).toRadixString(16).padLeft(16, '0'),
                      'blurVar': i.blurVariance,
                      'isBlurry': i.isBlurry,
                      'groupId': i.groupId,
                    })
                .toList())
            .toList(),
      };

  static Map<String, dynamic> _catMap(CleanCategorySummary c) => {
        'count': c.count,
        'size': c.size,
        'list': c.list
            .map((i) => {
                  'name': i.entry.name,
                  'hash': i.hash.toUnsigned(64).toRadixString(16).padLeft(16, '0'),
                  'blurVar': i.blurVariance,
                  'isBlurry': i.isBlurry,
                  'groupId': i.groupId,
                })
            .toList(),
      };
}

/// Analyze all entries at once and build categorical summary.
/// Categories are non-exclusive (duplicate/similar/blur can overlap). "other" are those not in any other tag.
Future<CleanAnalysisSummary> analyzeInMemorySummary(
  List<InMemoryImageEntry> entries, {
  int phashThreshold = 10,
  double blurThreshold = 250.0,
}) async {
  if (entries.isEmpty) {
    return CleanAnalysisSummary(
      all: const CleanCategorySummary(count: 0, size: 0, list: []),
      duplicate: const CleanCategorySummary(count: 0, size: 0, list: []),
      similar: const CleanCategorySummary(count: 0, size: 0, list: []),
      blur: const CleanCategorySummary(count: 0, size: 0, list: []),
      other: const CleanCategorySummary(count: 0, size: 0, list: []),
      groups: const [],
    );
  }

  final decodedEntries = <InMemoryImageEntry>[];
  final hashes = <BigInt>[];
  final blurVars = <double>[];

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
      decodedEntries.add(e);
      hashes.add(h);
      blurVars.add(bv);
    } catch (_) {}
  }

  // Build items (groupId assigned later)
  final items = List<ImageAnalysisItem>.generate(decodedEntries.length, (i) {
    return ImageAnalysisItem(
      entry: decodedEntries[i],
      hash: hashes[i],
      blurVariance: blurVars[i],
      isBlurry: blurVars[i] < blurThreshold,
      groupId: -1,
    );
  });

  if (items.isEmpty) {
    return CleanAnalysisSummary(
      all: const CleanCategorySummary(count: 0, size: 0, list: []),
      duplicate: const CleanCategorySummary(count: 0, size: 0, list: []),
      similar: const CleanCategorySummary(count: 0, size: 0, list: []),
      blur: const CleanCategorySummary(count: 0, size: 0, list: []),
      other: const CleanCategorySummary(count: 0, size: 0, list: []),
      groups: const [],
    );
  }

  final clusters = clusterByPhash(hashes, threshold: phashThreshold);
  final groups = <List<ImageAnalysisItem>>[];
  var nextGroupId = 0;

  // Duplicate & similar index sets
  final duplicateIdx = <int>{};
  final similarIdx = <int>{};

  for (final c in clusters) {
    if (c.length <= 1) continue;
    // assign group id
    for (final idx in c) {
      final old = items[idx];
      items[idx] = ImageAnalysisItem(
        entry: old.entry,
        hash: old.hash,
        blurVariance: old.blurVariance,
        isBlurry: old.isBlurry,
        groupId: nextGroupId,
      );
    }

    // pairwise distance classification
    for (var i = 0; i < c.length; i++) {
      for (var j = i + 1; j < c.length; j++) {
        final a = c[i];
        final b = c[j];
        final dist = hamming64(hashes[a], hashes[b]);
        if (dist == 0) {
          duplicateIdx.add(a);
          duplicateIdx.add(b);
        } else if (dist <= phashThreshold) {
          similarIdx.add(a);
          similarIdx.add(b);
        }
      }
    }

    groups.add(c.map((i) => items[i]).toList());
    nextGroupId++;
  }

  // similar excludes duplicates
  similarIdx.removeAll(duplicateIdx);

  final blurIdx = <int>{};
  for (var i = 0; i < items.length; i++) {
    if (items[i].isBlurry) blurIdx.add(i);
  }

  CleanCategorySummary buildCat(Set<int> idxSet) {
    final list = idxSet.map((i) => items[i]).toList();
    final size = list.fold<int>(0, (p, e) => p + e.entry.bytes.length);
    return CleanCategorySummary(count: list.length, size: size, list: list);
  }

  final allSize = items.fold<int>(0, (p, e) => p + e.entry.bytes.length);
  final allCat = CleanCategorySummary(count: items.length, size: allSize, list: [...items]);
  final dupCat = buildCat(duplicateIdx);
  final simCat = buildCat(similarIdx);
  final blurCat = buildCat(blurIdx);

  // other = items not in any of the above three sets
  final tagged = {...duplicateIdx, ...similarIdx, ...blurIdx};
  final otherSet = <int>{};
  for (var i = 0; i < items.length; i++) {
    if (!tagged.contains(i)) otherSet.add(i);
  }
  final otherCat = buildCat(otherSet);

  return CleanAnalysisSummary(
    all: allCat,
    duplicate: dupCat,
    similar: simCat,
    blur: blurCat,
    other: otherCat,
    groups: groups,
  );
}
