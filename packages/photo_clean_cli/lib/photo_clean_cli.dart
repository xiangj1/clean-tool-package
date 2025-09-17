library photo_clean_cli;

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:photo_clean_core/photo_clean_core.dart';

/// Entry point used by both the standalone executable and the workspace proxy.
Future<int> runCli(List<String> args, {IOSink? out, IOSink? err}) async {
  out ??= stdout;
  err ??= stderr;

  if (args.isEmpty) {
    _printUsage(err);
    return 64;
  }

  final directory = Directory(args.first);
  if (!directory.existsSync()) {
    err.writeln('Directory not found: ${args.first}');
    return 64;
  }

  final threshold = args.length > 1 ? int.tryParse(args[1]) ?? 10 : 10;
  final blurThreshold =
      args.length > 2 ? double.tryParse(args[2]) ?? 250.0 : 250.0;

  final files = await _collectImageFiles(directory);
  if (files.isEmpty) {
    out.writeln('No images found in ${directory.path}.');
    return 0;
  }

  final processedNames = <String>[];
  final hashes = <BigInt>[];
  final blurValues = <double>[];
  final skipped = <String>[];
  final basePath = directory.absolute.path;

  for (final file in files) {
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        skipped.add(file.path);
        continue;
      }

      final resized = img.copyResize(
        decoded,
        width: 256,
        height: 256,
        interpolation: img.Interpolation.linear,
      );

      final hash = pHash64(resized);
      final blur = laplacianVariance(resized);

      hashes.add(hash);
      blurValues.add(blur);
      processedNames.add(p.relative(file.path, from: basePath));
    } catch (_) {
      skipped.add(file.path);
    }
  }

  out.writeln(
      'Processed ${processedNames.length} images from ${directory.path}.');
  if (skipped.isNotEmpty) {
    out.writeln('Skipped ${skipped.length} files (failed to decode).');
  }

  if (hashes.isEmpty) {
    out.writeln('No decodable images found.');
    return skipped.isEmpty ? 0 : 1;
  }

  final clusters = clusterByPhash(hashes, threshold: threshold);
  final grouped = clusters.where((cluster) => cluster.length > 1).toList();

  if (grouped.isEmpty) {
    out.writeln('No similar image groups found (threshold $threshold).');
  } else {
    out.writeln('Similar image groups (threshold $threshold):');
    for (var i = 0; i < grouped.length; i++) {
      final cluster = grouped[i];
      out.writeln('Group ${i + 1} (size ${cluster.length}):');
      for (final index in cluster) {
        out.writeln('  ${processedNames[index]}');
      }
    }
  }

  final blurry = <String>[];
  for (var i = 0; i < processedNames.length; i++) {
    if (blurValues[i] < blurThreshold) {
      blurry.add(
        '${processedNames[i]} (variance ${blurValues[i].toStringAsFixed(2)})',
      );
    }
  }

  if (blurry.isEmpty) {
    out.writeln('No blurry images below threshold $blurThreshold.');
  } else {
    out.writeln('Potentially blurry images (variance < $blurThreshold):');
    for (final entry in blurry) {
      out.writeln('  $entry');
    }
  }

  return 0;
}

Future<List<File>> _collectImageFiles(Directory directory) async {
  final allowedExtensions = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'};
  final files = <File>[];
  await for (final entity
      in directory.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final ext = p.extension(entity.path).toLowerCase();
      if (allowedExtensions.contains(ext)) {
        files.add(entity);
      }
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

void _printUsage(IOSink sink) {
  sink.writeln(
    'Usage: dart run bin/photo_clean_cli.dart <images_folder> '
    '[phash_threshold=10] [blur_threshold=250]',
  );
}
