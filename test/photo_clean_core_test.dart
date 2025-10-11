import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:photo_clean_core/photo_clean_core.dart';
import 'package:test/test.dart';

void main() {
	img.Image pattern(int seed) {
		final im = img.Image(width: 40, height: 40);
		for (var y = 0; y < im.height; y++) {
			for (var x = 0; x < im.width; x++) {
				final v = (x * seed + y * 3) % 255;
				im.setPixelRgba(x, y, v, (v * 2) % 255, (v * 3) % 255, 255);
			}
		}
		return im;
	}

	test('stream final cleanInfo categories contain expected duplicate', () async {
		final a = pattern(7);
		final b = img.copyRotate(a, angle: 0); // identical content
		final c = pattern(11);
		final entries = [
			InMemoryImageEntry('a', Uint8List.fromList(img.encodePng(a))),
			InMemoryImageEntry('b', Uint8List.fromList(img.encodePng(b))),
			InMemoryImageEntry('c', Uint8List.fromList(img.encodePng(c))),
		];

		CleanInfoUpdatedEvent? last;
		await for (final ev in analyzeInMemoryStreaming(entries, phashThreshold: 5, regroupEvery: 3)) {
			last = ev as CleanInfoUpdatedEvent;
		}
		expect(last, isNotNull);
		final info = last!.cleanInfo;
		expect(info['all']['count'], 3);
		for (final k in ['duplicate','similar','blur','other','screenshot','video']) {
			expect(info.containsKey(k), isTrue, reason: 'missing $k');
		}
		final dupList = (info['duplicate']['list'] as List).cast<String>();
		expect(dupList.contains('a') && dupList.contains('b'), isTrue, reason: 'a & b should be duplicate');
	});
}
