library photo_clean_cli;

import 'dart:io';

import 'package:args/args.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:photo_clean_core/photo_clean_core.dart';

/// Entry point used by both the standalone executable and the workspace proxy.
Future<int> runCli(List<String> args, {IOSink? out, IOSink? err}) async {
  out ??= stdout;
  err ??= stderr;

  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addFlag('version', negatable: false, help: 'Show version info.')
    ..addCommand('analyze')
  ..addCommand('compress')
  ..addCommand('encrypt')
  ..addCommand('decrypt');

  if (args.isEmpty) {
    _printUsage(err);
    return 64;
  }

  final top = parser.parse([args.first]);
  if (top['help'] == true) {
    _printUsage(out);
    return 0;
  }
  if (top['version'] == true) {
    out.writeln('photo_clean_cli 0.1.0');
    return 0;
  }

  final command = args.first;
  final rest = args.skip(1).toList();
  switch (command) {
    case 'analyze':
      return _runAnalyze(rest, out: out, err: err);
    case 'compress':
      return _runCompress(rest, out: out, err: err);
    case 'encrypt':
      return _runEncrypt(rest, out: out, err: err);
    case 'decrypt':
      return _runDecrypt(rest, out: out, err: err);
    default:
      // Backward compatible: treat first arg as directory for analyze.
      return _runAnalyze(args, out: out, err: err);
  }
}

Future<int> _runAnalyze(List<String> args, {required IOSink out, required IOSink err}) async {
  if (args.isEmpty) {
    err.writeln('analyze requires a directory path.');
    _printUsage(err);
    return 64;
  }

  final directory = Directory(args.first);
  if (!directory.existsSync()) {
    err.writeln('Directory not found: ${args.first}');
    return 64;
  }

  final threshold = args.length > 1 ? int.tryParse(args[1]) ?? 10 : 10;
  final blurThreshold = args.length > 2 ? double.tryParse(args[2]) ?? 250.0 : 250.0;

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

  out.writeln('Processed ${processedNames.length} images from ${directory.path}.');
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
      blurry.add('${processedNames[i]} (variance ${blurValues[i].toStringAsFixed(2)})');
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

Future<int> _runCompress(List<String> args, {required IOSink out, required IOSink err}) async {
  // Simple manual parse (lightweight) to keep dependency minimal besides args lib already included.
  if (args.isEmpty) {
  err.writeln('compress requires <input_path> [--out <dir>] [--quality 85] [--max-width W] [--max-height H] [--format auto|jpeg|png] [--video-crf 28]');
    return 64;
  }

  final input = args.first;
  final rest = args.skip(1).toList();
  final map = <String, String>{};
  for (var i = 0; i < rest.length; i++) {
    final v = rest[i];
    if (v.startsWith('--')) {
      final key = v.substring(2);
      final next = (i + 1 < rest.length && !rest[i + 1].startsWith('--')) ? rest[++i] : 'true';
      map[key] = next;
    }
  }

  final quality = int.tryParse(map['quality'] ?? '85')?.clamp(1, 100) ?? 85;
  final maxWidth = int.tryParse(map['max-width'] ?? '0');
  final maxHeight = int.tryParse(map['max-height'] ?? '0');
  final formatStr = (map['format'] ?? 'auto').toLowerCase();
  final outDir = map['out'] != null ? Directory(map['out']!) : null;
  final videoCrf = int.tryParse(map['video-crf'] ?? '28') ?? 28;

  ImageOutputFormat fmt = ImageOutputFormat.auto;
  switch (formatStr) {
    case 'jpeg':
      fmt = ImageOutputFormat.jpeg;
      break;
    case 'png':
      fmt = ImageOutputFormat.png;
      break;
    case 'auto':
      fmt = ImageOutputFormat.auto;
      break;
    default:
      err.writeln('Unknown format: $formatStr');
      return 64;
  }

  final source = FileSystemEntity.typeSync(input);
  if (source == FileSystemEntityType.notFound) {
    err.writeln('Input not found: $input');
    return 64;
  }
  final targets = <File>[];
  if (source == FileSystemEntityType.directory) {
    final dir = Directory(input);
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        final ext = p.extension(e.path).toLowerCase();
        if (_imageExtensions.contains(ext) || _videoExtensions.contains(ext)) {
          targets.add(e);
        }
      }
    }
  } else if (source == FileSystemEntityType.file) {
    targets.add(File(input));
  }
  if (targets.isEmpty) {
    out.writeln('No media files to compress.');
    return 0;
  }

  out.writeln('Found ${targets.length} media files. Processing...');
  final results = <String>[];
  final imgOpts = ImageCompressionOptions(
    maxWidth: (maxWidth ?? 0) > 0 ? maxWidth : null,
    maxHeight: (maxHeight ?? 0) > 0 ? maxHeight : null,
    quality: quality,
    format: fmt,
  );

  for (final f in targets) {
    final ext = p.extension(f.path).toLowerCase();
    try {
      if (_imageExtensions.contains(ext)) {
        final bytes = await f.readAsBytes();
        final r = compressImageBytes(bytes, imgOpts);
        final relativeName = p.basenameWithoutExtension(f.path);
        final newExt = _extForFormat(r.chosenFormat, originalExt: ext);
        final outputDir = outDir ?? f.parent;
        if (!outputDir.existsSync()) outputDir.createSync(recursive: true);
        final outputPath = p.join(outputDir.path, '$relativeName$newExt');
        await File(outputPath).writeAsBytes(r.outputBytes);
        results.add('${p.relative(f.path)} -> ${p.relative(outputPath)} (${_fmtSize(r.originalSize)} -> ${_fmtSize(r.outputSize)}, ${r.savingPercent.toStringAsFixed(1)}%)');
      } else if (_videoExtensions.contains(ext)) {
        final outputDir = outDir ?? f.parent;
        if (!outputDir.existsSync()) outputDir.createSync(recursive: true);
        final outputPath = p.join(outputDir.path, p.basenameWithoutExtension(f.path) + '_compressed.mp4');
        final ok = await _compressVideo(f.path, outputPath, crf: videoCrf, out: out, err: err);
        if (ok) {
          final inSize = await f.length();
          final outSize = await File(outputPath).length();
            final ratio = (1 - outSize / (inSize == 0 ? 1 : inSize)) * 100;
          results.add('${p.relative(f.path)} -> ${p.relative(outputPath)} (${_fmtSize(inSize)} -> ${_fmtSize(outSize)}, ${ratio.toStringAsFixed(1)}%)');
        }
      }
    } catch (e) {
      err.writeln('Failed to compress ${f.path}: $e');
    }
  }

  out.writeln('Compression complete:');
  for (final line in results) {
    out.writeln('  $line');
  }

  return 0;
}

final _imageExtensions = {'.jpg', '.jpeg', '.png', '.bmp'};
final _videoExtensions = {'.mp4', '.mov', '.mkv', '.avi', '.webm'};

String _extForFormat(ImageOutputFormat f, {required String originalExt}) {
  switch (f) {
    case ImageOutputFormat.jpeg:
      return '.jpg';
    case ImageOutputFormat.png:
      return '.png';
    case ImageOutputFormat.auto:
      return originalExt; // Keep original extension when auto decided.
  }
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)}KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)}MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)}GB';
}

Future<bool> _compressVideo(String inputPath, String outputPath, {required int crf, required IOSink out, required IOSink err}) async {
  // Requires ffmpeg in PATH.
  final args = [
    'ffmpeg', '-y', '-i', inputPath,
    '-vcodec', 'libx264', '-crf', crf.toString(), '-preset', 'medium',
    '-acodec', 'aac', '-b:a', '128k',
    outputPath,
  ];
  try {
    final proc = await Process.start(args.first, args.skip(1).toList(), runInShell: true);
    await stdout.addStream(proc.stdout);
    await stderr.addStream(proc.stderr);
    final code = await proc.exitCode;
    if (code != 0) {
      err.writeln('ffmpeg failed for $inputPath (exit $code)');
      return false;
    }
    return true;
  } catch (e) {
    err.writeln('Error invoking ffmpeg: $e');
    return false;
  }
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
  sink.writeln('Photo Clean CLI');
  sink.writeln('');
  sink.writeln('Legacy (analyze default):');
  sink.writeln('  dart run bin/photo_clean_cli.dart <dir> [phash_threshold] [blur_threshold]');
  sink.writeln('');
  sink.writeln('Subcommands:');
  sink.writeln('  analyze <dir> [phash_threshold] [blur_threshold]');
  sink.writeln('  compress <input_path> [--out <dir>] [--quality 85] [--max-width W] [--max-height H]');
  sink.writeln('           [--format auto|jpeg|png] [--video-crf 28]');
  sink.writeln('  encrypt <file_or_dir> --password <pwd> [--out <dir>]');
  sink.writeln('  decrypt <file_or_dir> --password <pwd> [--out <dir>]');
  sink.writeln('');
  sink.writeln('Examples:');
  sink.writeln('  dart run bin/photo_clean_cli.dart analyze pictures 12 220');
  sink.writeln('  dart run bin/photo_clean_cli.dart compress pictures --out build/compressed --quality 80 --max-width 1920');
  sink.writeln('  dart run bin/photo_clean_cli.dart encrypt pictures --password secret');
  sink.writeln('  dart run bin/photo_clean_cli.dart decrypt encrypted --password secret --out restored');
}

Future<int> _runEncrypt(List<String> args, {required IOSink out, required IOSink err}) async {
  if (args.isEmpty) {
    err.writeln('encrypt requires <file_or_dir> --password <pwd>');
    return 64;
  }
  final input = args.first;
  final rest = args.skip(1).toList();
  final options = _parseKeyValue(rest);
  final password = options['password'];
  if (password == null || password.isEmpty) {
    err.writeln('Missing --password');
    return 64;
  }
  final outDir = options['out'] != null ? Directory(options['out']!) : null;
  final type = FileSystemEntity.typeSync(input);
  if (type == FileSystemEntityType.notFound) {
    err.writeln('Not found: $input');
    return 64;
  }
  final targets = await _gatherTargets(input, includeVideos: false);
  if (targets.isEmpty) {
    out.writeln('No image files to encrypt.');
    return 0;
  }
  out.writeln('Encrypting ${targets.length} files...');
  for (final f in targets) {
    try {
      final bytes = await f.readAsBytes();
      final b64 = encryptBytesToBase64Envelope(bytes, password);
      final outputDir = outDir ?? f.parent;
      if (!outputDir.existsSync()) outputDir.createSync(recursive: true);
      final outPath = p.join(outputDir.path, p.basename(f.path) + '.enc.txt');
      await File(outPath).writeAsString(b64);
      out.writeln('  ${p.relative(f.path)} -> ${p.relative(outPath)}');
    } catch (e) {
      err.writeln('Failed encrypt ${f.path}: $e');
    }
  }
  out.writeln('Encryption done.');
  return 0;
}

Future<int> _runDecrypt(List<String> args, {required IOSink out, required IOSink err}) async {
  if (args.isEmpty) {
    err.writeln('decrypt requires <file_or_dir> --password <pwd>');
    return 64;
  }
  final input = args.first;
  final rest = args.skip(1).toList();
  final options = _parseKeyValue(rest);
  final password = options['password'];
  if (password == null || password.isEmpty) {
    err.writeln('Missing --password');
    return 64;
  }
  final outDir = options['out'] != null ? Directory(options['out']!) : null;
  final type = FileSystemEntity.typeSync(input);
  if (type == FileSystemEntityType.notFound) {
    err.writeln('Not found: $input');
    return 64;
  }
  final List<File> targets = [];
  if (type == FileSystemEntityType.file) {
    targets.add(File(input));
  } else {
    final dir = Directory(input);
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('.enc.txt')) targets.add(e);
    }
  }
  if (targets.isEmpty) {
    out.writeln('No encrypted files (.enc.txt) found.');
    return 0;
  }
  out.writeln('Decrypting ${targets.length} files...');
  for (final f in targets) {
    try {
      final b64 = await f.readAsString();
      final plain = decryptBytesFromBase64Envelope(b64, password);
      // Guess original extension from removed .enc.txt (take one level back if possible)
      final baseOriginal = p.basename(f.path).replaceAll('.enc.txt', '');
      final outputDir = outDir ?? f.parent;
      if (!outputDir.existsSync()) outputDir.createSync(recursive: true);
      final outPath = p.join(outputDir.path, baseOriginal + '.dec');
      await File(outPath).writeAsBytes(plain);
      out.writeln('  ${p.relative(f.path)} -> ${p.relative(outPath)}');
    } catch (e) {
      err.writeln('Failed decrypt ${f.path}: $e');
    }
  }
  out.writeln('Decryption done.');
  return 0;
}

Map<String, String> _parseKeyValue(List<String> rest) {
  final map = <String, String>{};
  for (var i = 0; i < rest.length; i++) {
    final v = rest[i];
    if (v.startsWith('--')) {
      final key = v.substring(2);
      final next = (i + 1 < rest.length && !rest[i + 1].startsWith('--')) ? rest[++i] : 'true';
      map[key] = next;
    }
  }
  return map;
}

Future<List<File>> _gatherTargets(String input, {required bool includeVideos}) async {
  final type = FileSystemEntity.typeSync(input);
  final List<File> list = [];
  if (type == FileSystemEntityType.file) {
    final ext = p.extension(input).toLowerCase();
    if (_imageExtensions.contains(ext) || (includeVideos && _videoExtensions.contains(ext))) {
      list.add(File(input));
    }
  } else if (type == FileSystemEntityType.directory) {
    final dir = Directory(input);
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        final ext = p.extension(e.path).toLowerCase();
        if (_imageExtensions.contains(ext) || (includeVideos && _videoExtensions.contains(ext))) {
          list.add(e);
        }
      }
    }
  }
  return list;
}
