import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:photo_clean_core/photo_clean_core.dart';

void main() {
  group('encoding roundtrip (bytes only)', () {
    test('base64 token roundtrip', () {
      final original = Uint8List.fromList(List<int>.generate(128, (i) => (i * 13) % 256));
      final token = encryptBytes(original);
      final restored = decryptToBytes(token);
      expect(restored, equals(original));
    });
  });
}
