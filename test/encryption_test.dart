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

    test('entry encode then decode entry', () {
      final entry = InMemoryImageEntry('sample.jpg', Uint8List.fromList([1,2,3,4,5]));
      final token = encryptEntry(entry);
      final restoredEntry = decryptToEntry(token, name: 'restored.jpg');
      expect(restoredEntry.bytes, isNotNull);
      expect(restoredEntry.bytes, equals(entry.bytes));
    });
  });
}
