import 'package:flutter_test/flutter_test.dart';
import 'package:material3_showcase/src/speed_test_models.dart';
import 'package:material3_showcase/src/speed_test_service.dart';

void main() {
  group('SpeedTestService.normalizeHost', () {
    test('accepts valid hostnames and ip addresses', () {
      expect(
        SpeedTestService.normalizeHost('mensura.cdn-apple.com'),
        'mensura.cdn-apple.com',
      );
      expect(
        SpeedTestService.normalizeHost(
          'HTTPS://HKHKG1-EDGE-BX-002.AAPLIMG.COM',
        ),
        'hkhkg1-edge-bx-002.aaplimg.com',
      );
      expect(SpeedTestService.normalizeHost('https://1.1.1.1/path'), '1.1.1.1');
    });

    test('rejects empty and malformed values', () {
      expect(SpeedTestService.normalizeHost(''), isNull);
      expect(SpeedTestService.normalizeHost('   '), isNull);
      expect(SpeedTestService.normalizeHost('..'), isNull);
      expect(SpeedTestService.normalizeHost('a b'), isNull);
      expect(SpeedTestService.normalizeHost('abc'), isNull);
      expect(SpeedTestService.normalizeHost('foo_bar.com'), isNull);
      expect(SpeedTestService.normalizeHost('https://'), isNull);
    });
  });

  group('sanitizeEndpointHost', () {
    test('keeps placeholder labels unchanged', () {
      expect(sanitizeEndpointHost('等待测速节点'), '等待测速节点');
    });

    test('strips repeated trailing ip suffixes', () {
      expect(
        sanitizeEndpointHost('mensura.cdn-apple.com [1.1.1.1] [1.1.1.1]'),
        'mensura.cdn-apple.com',
      );
    });

    test('extracts host from full url', () {
      expect(
        sanitizeEndpointHost('https://mensura.cdn-apple.com/path?q=1'),
        'mensura.cdn-apple.com',
      );
    });
  });
}
