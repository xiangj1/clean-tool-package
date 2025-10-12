library photo_clean_core;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'package:image/image.dart' as img;

/// Simple in-memory image holder (name + raw bytes).
enum MediaType { image, screenshot, video }

class InMemoryImageEntry {
  final String name;
  Uint8List? bytes; // may be nulled after processing to release memory
  final int originalSize;
  final MediaType type;

  InMemoryImageEntry(this.name, Uint8List bytes, {this.type = MediaType.image})
      : bytes = bytes,
        originalSize = bytes.length;

  int get size => bytes?.length ?? originalSize;
  bool get isBytesDiscarded => bytes == null;
}

/// Base event type (kept for future extensibility: progress/error, etc.).
abstract class StreamingAnalysisEvent {
  const StreamingAnalysisEvent();
}

/// Batch classification snapshot emitted every [regroupEvery] images and at end.
class CleanInfoUpdatedEvent extends StreamingAnalysisEvent {
  final Map<String, dynamic> cleanInfo;

  const CleanInfoUpdatedEvent(this.cleanInfo);
}

/// Incremental (dynamic push) analyzer.
///
/// Use when you cannot or do not want to allocate a giant `List<InMemoryImageEntry>` up-front
/// (e.g. > several thousand images). You push entries one-by-one (or in small batches) via
/// [add] / [addAll]; when the internal processed count reaches each multiple of [regroupEvery]
/// a classification snapshot is emitted on [stream]. Call [close] after the final add to emit
/// a last snapshot if the last batch was incomplete
class InMemoryStreamingAnalyzer {
  final int phashThreshold;
  final double blurThreshold;
  final int regroupEvery;
  final bool discardBytesAfterProcessing;

  final _hashes = <BigInt>[];
  final _entries = <InMemoryImageEntry>[];
  final _blurFlags = <bool>[];
  final _controller = StreamController<StreamingAnalysisEvent>.broadcast();
  bool _closed = false;
  Future<void> _chain = Future.value();

  InMemoryStreamingAnalyzer({
    this.phashThreshold = 10,
    this.blurThreshold = 250.0,
    int regroupEvery = 50,
    this.discardBytesAfterProcessing = true,
  }) : regroupEvery = regroupEvery < 1 ? 1 : regroupEvery;

  Stream<StreamingAnalysisEvent> get stream => _controller.stream;

  /// Add a single entry (queued sequentially). Returns when processing completed and a snapshot
  /// may have been emitted.
  Future<void> add(InMemoryImageEntry entry) {
    if (_closed) return Future.value();
  _chain = _chain.then((_) async {
      try {
  final data = entry.bytes; // if already discarded (shouldn't happen), skip
  if (data == null) return;
  final decoded = img.decodeImage(data);
        if (decoded == null) return;
        final norm = img.copyResize(
          decoded,
          width: 256,
          height: 256,
          interpolation: img.Interpolation.linear,
        );
        _hashes.add(_pHash64(norm));
        _blurFlags.add(_laplacianVariance(norm) < blurThreshold);
        _entries.add(entry);
        if (discardBytesAfterProcessing) {
          entry.bytes = null; // free reference
        }
        if (_entries.length % regroupEvery == 0) {
          _controller.add(CleanInfoUpdatedEvent(
            _buildSnapshot(_hashes, _entries, _blurFlags, phashThreshold),
          ));
        }
      } catch (_) {
        // swallow individual decode errors
      }
    });
    return _chain;
  }

  /// Add multiple entries in order.
  Future<void> addAll(Iterable<InMemoryImageEntry> list) async {
    for (final e in list) {
      await add(e); // preserve order & batching semantics
    }
  }

  /// Finish the stream and emit a final snapshot if the last batch wasn't a full multiple.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _chain; // ensure all queued work done
    if (_entries.isNotEmpty && _entries.length % regroupEvery != 0) {
      _controller.add(CleanInfoUpdatedEvent(
        _buildSnapshot(_hashes, _entries, _blurFlags, phashThreshold),
      ));
    }
    await _controller.close();
  }
}

// ---- Internal algorithms (now private) ----
BigInt _pHash64(
  img.Image image, {
  int size = 32,
  int dctSize = 8,
}) {
  final resized = img.copyResize(
    image,
    width: size,
    height: size,
    interpolation: img.Interpolation.linear,
  );
  final g = img.grayscale(resized);

  final matrix = List.generate(
    size,
    (y) => List<double>.generate(
      size,
      (x) => g.getPixel(x, y).luminance.toDouble(),
      growable: false,
    ),
    growable: false,
  );

  final d = _dct2D(matrix);
  final coeffs = <double>[];
  for (var v = 0; v < dctSize; v++) {
    for (var u = 0; u < dctSize; u++) {
      coeffs.add(d[v][u]);
    }
  }
  if (coeffs.isEmpty) return BigInt.zero;

  final mid = _median(coeffs.sublist(1));
  BigInt h = BigInt.zero;
  for (var i = 0; i < coeffs.length; i++) {
    h <<= 1;
    if (i == 0) continue; // skip DC
    if (coeffs[i] > mid) h |= BigInt.one;
  }
  return h;
}

int _hamming64(BigInt a, BigInt b) {
  var v = a ^ b;
  var c = 0;
  while (v != BigInt.zero) {
    v &= (v - BigInt.one);
    c++;
  }
  return c;
}

double _laplacianVariance(img.Image image) {
  final g = image.numChannels == 1 ? image : img.grayscale(image);
  if (g.width < 3 || g.height < 3) return 0.0;

  final resp = <double>[];
  for (var y = 1; y < g.height - 1; y++) {
    for (var x = 1; x < g.width - 1; x++) {
      double lum(int dx, int dy) =>
          g.getPixel(x + dx, y + dy).luminance.toDouble();
      final value =
          lum(0, -1) + lum(-1, 0) + lum(1, 0) + lum(0, 1) - 4 * lum(0, 0);
      resp.add(value);
    }
  }
  if (resp.isEmpty) return 0.0;

  var sum = 0.0;
  for (final r in resp) {
    sum += r;
  }
  final mean = sum / resp.length;
  var sq = 0.0;
  for (final r in resp) {
    final d = r - mean;
    sq += d * d;
  }
  return sq / resp.length;
}

/// Stream images; emit classification snapshot per batch.
Stream<StreamingAnalysisEvent> analyzeInMemoryStreaming(
  List<InMemoryImageEntry> entries, {
  int phashThreshold = 10,
  double blurThreshold = 250.0,
  int regroupEvery = 50,
  bool discardBytesAfterProcessing = true,
}) async* {
  if (entries.isEmpty) return;
  if (regroupEvery < 1) regroupEvery = 1;
  final hashes = <BigInt>[];
  final processed = <InMemoryImageEntry>[];
  final blurFlags = <bool>[];
  for (final e in entries) {
    try {
  final data = e.bytes;
  if (data == null) continue; // already discarded somehow
  final decoded = img.decodeImage(data);
      if (decoded == null) continue;
      final norm = img.copyResize(
        decoded,
        width: 256,
        height: 256,
        interpolation: img.Interpolation.linear,
      );
      hashes.add(_pHash64(norm));
      blurFlags.add(_laplacianVariance(norm) < blurThreshold);
      processed.add(e);
      if (discardBytesAfterProcessing) {
        e.bytes = null;
      }
      if (processed.length % regroupEvery == 0) {
        yield CleanInfoUpdatedEvent(
          _buildSnapshot(hashes, processed, blurFlags, phashThreshold),
        );
      }
    } catch (_) {}
  }
  if (processed.isNotEmpty && processed.length % regroupEvery != 0) {
    yield CleanInfoUpdatedEvent(
      _buildSnapshot(hashes, processed, blurFlags, phashThreshold),
    );
  }
}

// ---- Internal helpers ----
Map<String, dynamic> _buildSnapshot(
  List<BigInt> hashes,
  List<InMemoryImageEntry> entries,
  List<bool> blurFlags,
  int thr,
) {
  final clusters = _cluster(hashes, thr);
  final dup = <String>{};
  final sim = <String>{};
  final blur = <String>{};
  final screenshot = <String>{};
  final video = <String>{};

  for (final c in clusters) {
    for (var i = 0; i < c.length; i++) {
      for (var j = i + 1; j < c.length; j++) {
        final ia = c[i];
        final ib = c[j];
        final d = _hamming64(hashes[ia], hashes[ib]);
        if (d == 0) {
          dup..add(entries[ia].name)..add(entries[ib].name);
        } else if (d <= thr) {
          sim..add(entries[ia].name)..add(entries[ib].name);
        }
      }
    }
  }

  sim.removeAll(dup);

  for (var i = 0; i < entries.length; i++) {
    if (blurFlags[i]) {
      blur.add(entries[i].name);
    }
  }

  // collect explicit media types
  for (final e in entries) {
    switch (e.type) {
      case MediaType.screenshot:
        screenshot.add(e.name);
        break;
      case MediaType.video:
        video.add(e.name);
        break;
      case MediaType.image:
        break;
    }
  }

  final totalSize = entries.fold<int>(0, (p, e) => p + e.size);

  Map<String, dynamic> pack(Set<String> names) {
    final list = entries.where((e) => names.contains(e.name)).toList();
    return {
      'count': list.length,
      'size': list.fold<int>(0, (p, e) => p + e.size),
      'list': list.map((e) => e.name).toList(),
    };
  }

  final tagged = {...dup, ...sim, ...blur, ...screenshot, ...video};
  final other = entries
      .where((e) => !tagged.contains(e.name))
      .map((e) => e.name)
      .toSet();

  return {
    'all': {
      'count': entries.length,
      'size': totalSize,
      'list': entries.map((e) => e.name).toList(),
    },
    'duplicate': pack(dup),
    'similar': pack(sim),
    'blur': pack(blur),
    'screenshot': pack(screenshot),
    'video': pack(video),
    'other': pack(other),
  };
}

List<List<int>> _cluster(List<BigInt> hashes, int thr) {
  if (hashes.isEmpty) return [];

  final parent = List<int>.generate(hashes.length, (i) => i);

  int find(int i) => parent[i] == i ? i : (parent[i] = find(parent[i]));

  void uni(int a, int b) {
    a = find(a);
    b = find(b);
    if (a != b) parent[b] = a;
  }

  for (var i = 0; i < hashes.length; i++) {
    for (var j = i + 1; j < hashes.length; j++) {
      if (_hamming64(hashes[i], hashes[j]) <= thr) {
        uni(i, j);
      }
    }
  }

  final map = <int, List<int>>{};
  for (var i = 0; i < hashes.length; i++) {
    final r = find(i);
    (map[r] ??= <int>[]).add(i);
  }

  final res = map.values.map((g) => (g..sort())).toList()
    ..sort((a, b) => a.first.compareTo(b.first));
  return res;
}

List<List<double>> _dct2D(List<List<double>> input) {
  final n = input.length;
  final out = List.generate(
    n,
    (_) => List<double>.filled(n, 0.0, growable: false),
    growable: false,
  );
  final f = math.pi / (2 * n);
  final cosX = List.generate(
    n,
    (u) => List.generate(
      n,
      (x) => math.cos((2 * x + 1) * u * f),
      growable: false,
    ),
    growable: false,
  );
  final cosY = List.generate(
    n,
    (v) => List.generate(
      n,
      (y) => math.cos((2 * y + 1) * v * f),
      growable: false,
    ),
    growable: false,
  );
  final s0 = math.sqrt(1.0 / n);
  final s = math.sqrt(2.0 / n);

  for (var v = 0; v < n; v++) {
    for (var u = 0; u < n; u++) {
      var sum = 0.0;
      for (var y = 0; y < n; y++) {
        final row = input[y];
        final cy = cosY[v][y];
        for (var x = 0; x < n; x++) {
          sum += row[x] * cosX[u][x] * cy;
        }
      }
      out[v][u] = (u == 0 ? s0 : s) * (v == 0 ? s0 : s) * sum;
    }
  }
  return out;
}

double _median(List<double> v) {
  if (v.isEmpty) return 0.0;
  v = [...v]..sort();
  final m = v.length >> 1;
  if (v.length.isOdd) return v[m];
  return (v[m - 1] + v[m]) / 2.0;
}

/// Convenience factory to create a dynamic analyzer.
InMemoryStreamingAnalyzer createStreamingAnalyzer({
  int phashThreshold = 10,
  double blurThreshold = 250.0,
  int regroupEvery = 50,
}) => InMemoryStreamingAnalyzer(
      phashThreshold: phashThreshold,
      blurThreshold: blurThreshold,
      regroupEvery: regroupEvery,
    );

// ---------------------------------------------------------------------------
// Simple (non-cryptographic) encode / decode helpers
// ---------------------------------------------------------------------------
/// Encrypt (actually: obfuscate + base64) raw bytes or an [InMemoryImageEntry].
///
/// This is NOT secure strong encryption—it's only base64 + optional XOR mask to avoid
/// plain storage. For real security use a proven crypto library (e.g. PointyCastle).
///
/// Returns a string with format: `v1:<hexKeyUsed>:<base64Payload>` where hexKeyUsed is
/// the (possibly truncated) XOR key bytes in hex (empty if no key supplied).
String encryptBytes(
  Uint8List data, {
  String? xorKey,
}) {
  final keyBytes = xorKey == null || xorKey.isEmpty
      ? null
      : utf8.encode(xorKey); // simple utf8 key
  Uint8List payload;
  if (keyBytes == null) {
    payload = data;
  } else {
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      out[i] = data[i] ^ keyBytes[i % keyBytes.length];
    }
    payload = out;
  }
  final b64 = base64Encode(payload);
  final keyHex = keyBytes == null
      ? ''
      : keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'v1:$keyHex:$b64';
}

/// Convenience: encrypt an [InMemoryImageEntry]. If [entry.bytes] was discarded the
/// call throws.
String encryptEntry(InMemoryImageEntry entry, {String? xorKey}) {
  final data = entry.bytes;
  if (data == null) {
    throw StateError('Entry bytes have been discarded; cannot encrypt.');
  }
  return encryptBytes(data, xorKey: xorKey);
}

/// Decrypt previously encoded string from [encryptBytes]/[encryptEntry].
/// Auto-detects version prefix. Throws [FormatException] if malformed.
Uint8List decryptToBytes(String token, {String? xorKey}) {
  if (!token.startsWith('v1:')) {
    throw FormatException('Unsupported token version');
  }
  final parts = token.split(':');
  if (parts.length != 3) {
    throw FormatException('Malformed token');
  }
  final keyHex = parts[1];
  final payloadB64 = parts[2];
  final bytes = base64Decode(payloadB64);
  final keyProvided = xorKey != null && xorKey.isNotEmpty;
  if (keyHex.isEmpty) {
    if (keyProvided) {
      // user gave key but original had none; ignore key
    }
    return Uint8List.fromList(bytes);
  }
  if (!keyProvided) {
    throw FormatException('Token requires xorKey but none provided');
  }
  final expectedKeyHex = utf8
    .encode(xorKey)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  if (expectedKeyHex != keyHex) {
    throw FormatException('xorKey mismatch');
  }
  final out = Uint8List(bytes.length);
  final keyBytes = utf8.encode(xorKey);
  for (var i = 0; i < bytes.length; i++) {
    out[i] = bytes[i] ^ keyBytes[i % keyBytes.length];
  }
  return out;
}

/// Decrypt and wrap as an [InMemoryImageEntry]. Caller provides a name & optional media type.
InMemoryImageEntry decryptToEntry(
  String token, {
  required String name,
  MediaType type = MediaType.image,
  String? xorKey,
}) {
  final data = decryptToBytes(token, xorKey: xorKey);
  return InMemoryImageEntry(name, data, type: type);
}
