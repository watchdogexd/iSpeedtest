import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ispeedtest/src/speed_test_models.dart';
import 'package:ispeedtest/src/speed_test_service.dart';

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

    test('strips trailing ip suffixes when control characters exist', () {
      expect(
        sanitizeEndpointHost('mensura.cdn-apple.com [1.1.1.1] [1.1.1.1]\u001e'),
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

  group('SpeedTestService upload', () {
    test('uses fixed default endpoint host from config payload', () {
      final config = SpeedTestConfig.fromJson({
        'test_endpoint': 'hkhkg1-edge-bx-021.aaplimg.com',
        'urls': {
          'small_https_download_url':
              'https://mensura.cdn-apple.com/api/v1/gm/small',
          'large_https_download_url':
              'https://mensura.cdn-apple.com/api/v1/gm/large',
          'https_upload_url': 'https://mensura.cdn-apple.com/api/v1/gm/slurp',
        },
      });

      expect(config.testEndpoint, defaultSpeedTestEndpointHost);
      expect(config.smallDownloadUri.host, defaultSpeedTestEndpointHost);
      expect(config.largeDownloadUri.host, defaultSpeedTestEndpointHost);
      expect(config.uploadUri.host, defaultSpeedTestEndpointHost);
    });

    test('measures upload throughput for each mode', () async {
      final harness = await _UploadTestHarness.start();
      addTearDown(harness.close);

      for (final mode in SpeedTestMode.values) {
        final service = SpeedTestService.test(
          uploadDuration: const Duration(milliseconds: 650),
          uploadGraceDuration: const Duration(milliseconds: 250),
        );
        final progressUpdates = <SpeedTestProgress>[];

        final result = await service.measureUploadForTesting(
          config: harness.config,
          mode: mode,
          downloadMbps: 123.4,
          downloadedBytes: 4096,
          onProgress: progressUpdates.add,
        );

        expect(result.mode, mode);
        expect(result.endpoint, harness.host);
        expect(result.uploadedBytes, greaterThan(0));
        expect(result.uploadMbps, greaterThan(0));
        expect(progressUpdates, isNotEmpty);
        expect(
          progressUpdates.any((item) => item.statusMessage.startsWith('上传测速中')),
          isTrue,
        );
        expect(progressUpdates.last.phase, SpeedTestPhase.uploading);
        expect(progressUpdates.last.statusMessage, '上传测速完成');
        expect(progressUpdates.last.phaseProgress, 1);
        expect(progressUpdates.last.overallProgress, 0.98);
        expect(progressUpdates.last.downloadMbps, 123.4);
        expect(progressUpdates.last.downloadedBytes, 4096);
        expect(progressUpdates.last.uploadedBytes, result.uploadedBytes);
        expect(progressUpdates.last.uploadMbps, result.uploadMbps);
      }
    });

    test('throws when all upload workers fail', () async {
      final harness = await _UploadTestHarness.start(rejectUploads: true);
      addTearDown(harness.close);

      final service = SpeedTestService.test(
        uploadDuration: const Duration(milliseconds: 650),
        uploadGraceDuration: const Duration(milliseconds: 250),
      );
      final progressUpdates = <SpeedTestProgress>[];

      await expectLater(
        service.measureUploadForTesting(
          config: harness.config,
          mode: SpeedTestMode.multiThread,
          downloadMbps: 10,
          downloadedBytes: 1024,
          onProgress: progressUpdates.add,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Upload failed after 4 network faults',
          ),
        ),
      );

      expect(progressUpdates, isNotEmpty);
      expect(
        progressUpdates.any((item) => item.statusMessage.startsWith('上传测速中')),
        isTrue,
      );
    });

    test('keeps partial success and reports fault count', () async {
      final harness = await _UploadTestHarness.start(
        failRequestNumbers: <int>{1, 3},
      );
      addTearDown(harness.close);

      final service = SpeedTestService.test(
        uploadDuration: const Duration(milliseconds: 650),
        uploadGraceDuration: const Duration(milliseconds: 250),
      );
      final progressUpdates = <SpeedTestProgress>[];

      final result = await service.measureUploadForTesting(
        config: harness.config,
        mode: SpeedTestMode.multiThread,
        downloadMbps: 10,
        downloadedBytes: 1024,
        onProgress: progressUpdates.add,
      );

      expect(result.uploadedBytes, greaterThan(0));
      expect(harness.serverRejectedBytes, greaterThan(0));
      expect(
        result.uploadedBytes,
        lessThan(harness.serverAcceptedBytes + harness.serverRejectedBytes),
      );
      expect(result.uploadMbps, greaterThan(0));
      expect(progressUpdates.last.statusMessage, '上传测速完成 · 2 次网络波动');
      expect(progressUpdates.last.uploadedBytes, result.uploadedBytes);
      expect(progressUpdates.last.uploadMbps, result.uploadMbps);
    });

    test('keeps written bytes when upload response times out', () async {
      final harness = await _UploadTestHarness.start(
        responseDelay: const Duration(milliseconds: 750),
      );
      addTearDown(harness.close);

      final service = SpeedTestService.test(
        uploadDuration: const Duration(milliseconds: 300),
        uploadGraceDuration: const Duration(milliseconds: 100),
      );
      final stopwatch = Stopwatch()..start();

      final result = await service.measureUploadForTesting(
        config: harness.config,
        mode: SpeedTestMode.singleThread,
        downloadMbps: 10,
        downloadedBytes: 1024,
        onProgress: (_) {},
      );
      stopwatch.stop();

      expect(result.uploadedBytes, greaterThan(0));
      expect(result.uploadMbps, greaterThan(0));
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1200)));
    });

    test('resolves auto ip with selected doh provider', () async {
      final service = SpeedTestService.test(
        resolveHostWithDoh: (host, provider) async {
          return DohResolution(
            host: host,
            ipv4: <String>['ipv4-${provider.name}'],
            ipv6: const <String>[],
            resolver: provider.resolverName,
            resolvedAt: DateTime.now(),
          );
        },
      );

      final googleIp = await service.resolvePreferredAutoIpForTesting(
        defaultSpeedTestEndpointHost,
        DohProvider.google,
      );
      final cloudflareIp = await service.resolvePreferredAutoIpForTesting(
        defaultSpeedTestEndpointHost,
        DohProvider.cloudflare,
      );

      expect(googleIp, 'ipv4-google');
      expect(cloudflareIp, 'ipv4-cloudflare');
    });
  });
}

class _UploadTestHarness {
  _UploadTestHarness._({
    required this.host,
    required HttpServer server,
    required this.rejectUploads,
    required Set<int> failRequestNumbers,
    required this.responseDelay,
  }) : _server = server,
       _failRequestNumbers = failRequestNumbers,
       config = SpeedTestConfig(
         testEndpoint: host,
         smallDownloadUri: Uri(
           scheme: 'http',
           host: host,
           port: server.port,
           path: '/small',
         ),
         largeDownloadUri: Uri(
           scheme: 'http',
           host: host,
           port: server.port,
           path: '/large',
         ),
         uploadUri: Uri(
           scheme: 'http',
           host: host,
           port: server.port,
           path: '/upload',
         ),
         fallbackSmallDownloadUri: Uri(
           scheme: 'http',
           host: host,
           port: server.port,
           path: '/small',
         ),
         fallbackLargeDownloadUri: Uri(
           scheme: 'http',
           host: host,
           port: server.port,
           path: '/large',
         ),
         fallbackUploadUri: Uri(
           scheme: 'http',
           host: host,
           port: server.port,
           path: '/upload',
         ),
       );

  final String host;
  final HttpServer _server;
  final SpeedTestConfig config;
  final bool rejectUploads;
  final Set<int> _failRequestNumbers;
  final Duration responseDelay;
  var serverAcceptedBytes = 0;
  var serverRejectedBytes = 0;
  var _requestCount = 0;
  late final StreamSubscription<HttpRequest> _subscription;

  static Future<_UploadTestHarness> start({
    bool rejectUploads = false,
    Set<int> failRequestNumbers = const <int>{},
    Duration responseDelay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final harness = _UploadTestHarness._(
      host: InternetAddress.loopbackIPv4.address,
      server: server,
      rejectUploads: rejectUploads,
      failRequestNumbers: failRequestNumbers,
      responseDelay: responseDelay,
    );
    harness._subscription = server.listen((request) {
      unawaited(harness._handleRequest(request));
    });
    return harness;
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final requestNumber = ++_requestCount;

    if (request.method != 'PUT' || request.uri.path != '/upload') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    var receivedBytes = 0;
    await for (final chunk in request) {
      receivedBytes += chunk.length;
    }

    final shouldReject =
        rejectUploads || _failRequestNumbers.contains(requestNumber);
    if (shouldReject) {
      serverRejectedBytes += receivedBytes;
    } else {
      serverAcceptedBytes += receivedBytes;
    }
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    request.response.statusCode = shouldReject
        ? HttpStatus.serviceUnavailable
        : (receivedBytes > 0 ? HttpStatus.ok : HttpStatus.badRequest);
    request.response.write('ok');
    try {
      await request.response.close();
    } on SocketException {
      // The client may abort after its response timeout; the received body is
      // still valid for upload accounting.
    }
  }
}
