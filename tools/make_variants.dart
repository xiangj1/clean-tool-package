import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final srcDir = Directory('pictures');
  final outDir = Directory('pictures/variants');
  if (!srcDir.existsSync()) {
    print('Source directory not found: pictures');
    return;
  }
  outDir.createSync(recursive: true);

  final files = srcDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.jpg') || f.path.toLowerCase().endsWith('.jpeg') || f.path.toLowerCase().endsWith('.png'))
      .toList();

  var idx = 0;
  for (final file in files) {
    try {
      final bytes = file.readAsBytesSync();
      final image = img.decodeImage(bytes);
      if (image == null) continue;

      idx++;
      final base = 'img_${idx}';

      // 1) exact copy
      File('${outDir.path}/${base}_copy.jpg').writeAsBytesSync(img.encodeJpg(image));

      // 2) cropped center (90%)
      final cropW = (image.width * 0.9).toInt();
      final cropH = (image.height * 0.9).toInt();
      final cropped = img.copyCrop(image,
          x: (image.width - cropW) ~/ 2,
          y: (image.height - cropH) ~/ 2,
          width: cropW,
          height: cropH);
      File('${outDir.path}/${base}_crop.jpg').writeAsBytesSync(img.encodeJpg(cropped));

      // 3) mild blur via gaussian (if available) else downscale-upscale
      img.Image mildBlur;
      try {
        mildBlur = img.gaussianBlur(image, radius: 6);
      } catch (_) {
        final small = img.copyResize(image, width: (image.width / 10).round());
        mildBlur = img.copyResize(small, width: image.width, height: image.height, interpolation: img.Interpolation.average);
      }
      File('${outDir.path}/${base}_mild_blur.jpg').writeAsBytesSync(img.encodeJpg(mildBlur));

      // 4) heavy blur (downscale more)
      final tiny = img.copyResize(image, width: (image.width / 20).round());
      final heavyBlur = img.copyResize(tiny, width: image.width, height: image.height, interpolation: img.Interpolation.average);
      File('${outDir.path}/${base}_heavy_blur.jpg').writeAsBytesSync(img.encodeJpg(heavyBlur));

      // 5) slight brightness change
      final brighter = img.adjustColor(image, gamma: 1.0, contrast: 1.02, brightness: 10);
      File('${outDir.path}/${base}_brighter.jpg').writeAsBytesSync(img.encodeJpg(brighter));

      // Also create a second variant from the same original to ensure grouping
      final secondCrop = img.copyCrop(image,
          x: 0,
          y: 0,
          width: (image.width * 0.8).toInt(),
          height: (image.height * 0.8).toInt());
      File('${outDir.path}/${base}_second_crop.jpg').writeAsBytesSync(img.encodeJpg(secondCrop));
    } catch (e) {
      print('Failed to process ${file.path}: $e');
    }
  }

  print('Generated variants for $idx source images in ${outDir.path}');
}
