import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:photo_clean_core/photo_clean_core.dart';

void main(List<String> args) async {
  final phashThreshold = args.isNotEmpty ? int.tryParse(args[0]) ?? 10 : 10;
  final blurThreshold = args.length > 1 ? double.tryParse(args[1]) ?? 250.0 : 250.0;

  final src = Directory('pictures');
  if (!src.existsSync()) {
    stderr.writeln('Directory not found: pictures');
    exit(2);
  }

  final files = <File>[];
  await for (final e in src.list(recursive: true, followLinks: false)) {
    if (e is File) {
      final ext = e.path.toLowerCase();
      if (ext.endsWith('.jpg') || ext.endsWith('.jpeg') || ext.endsWith('.png') || ext.endsWith('.bmp') || ext.endsWith('.webp')) {
        files.add(e);
      }
    }
  }

  if (files.isEmpty) {
    print('No images found in ${src.path}.');
    return;
  }

  final hashes = <BigInt>[];
  final variances = <double>[];
  final processedNames = <String>[];

  for (final file in files) {
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        continue;
      }
      final h = pHash64(decoded);
      final v = laplacianVariance(decoded);
      hashes.add(h);
      variances.add(v);
      processedNames.add(file.path);
    } catch (_) {
      // skip
    }
  }

  print('Computed ${hashes.length} image hashes and variances.');

  final clusters = clusterByPhash(hashes, threshold: phashThreshold);

  print('\nSimilar groups (phash threshold: $phashThreshold):');
  var gid = 0;
  for (final cluster in clusters.where((c) => c.length > 1)) {
    gid++;
    print('\nGroup $gid (size ${cluster.length}):');
    for (final i in cluster) {
      print('  - ${processedNames[i]}  (phash: ${phashHex(hashes[i])})');
    }

    // pairwise similarities
    print('  Pairwise similarities (percent):');
    for (var i = 0; i < cluster.length; i++) {
      for (var j = i + 1; j < cluster.length; j++) {
        final ia = cluster[i];
        final ja = cluster[j];
        final hd = hamming64(hashes[ia], hashes[ja]);
        final similarity = similarityPercentFromHashes(hashes[ia], hashes[ja]);
        print('    ${processedNames[ia]} <-> ${processedNames[ja]} : ${similarity.toStringAsFixed(2)}% (hamming=$hd)');
      }
    }
  }

  print('\nPotentially blurry images (variance < $blurThreshold):');
  final blurry = <Map<String, dynamic>>[];
  for (var i = 0; i < variances.length; i++) {
    if (variances[i] < blurThreshold) {
      blurry.add({'path': processedNames[i], 'variance': variances[i]});
    }
  }
  blurry.sort((a, b) => (a['variance'] as double).compareTo(b['variance'] as double));
  for (final e in blurry) {
    print('  - ${e['path']} (variance: ${(e['variance'] as double).toStringAsFixed(2)})');
  }

  print('\nDone.');
}
