import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:photo_clean_core/photo_clean_core.dart';

void main() {
  group('encryption roundtrip', () {
    test('encrypt/decrypt without key', () {
      final original = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final token = encryptBytes(original);
      final restored = decryptToBytes(token);
      expect(restored, equals(original));
    });

    test('encrypt/decrypt with key', () {
      final data = Uint8List.fromList(List<int>.generate(128, (i) => (i * 7) % 256));
      final token = encryptBytes(data, xorKey: 'secret');
      final out = decryptToBytes(token, xorKey: 'secret');
      expect(out, equals(data));
    });

    test('entry encrypt then decrypt entry', () {
      final entry = InMemoryImageEntry('sample.jpg', Uint8List.fromList([1,2,3,4,5]));
      final token = encryptEntry(entry, xorKey: 'k');
      final restoredEntry = decryptToEntry(token, name: 'restored.jpg', xorKey: 'k');
      expect(restoredEntry.bytes, isNotNull);
      expect(restoredEntry.bytes, equals(entry.bytes));
    });
  });
}
