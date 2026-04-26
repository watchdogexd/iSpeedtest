import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _defaultEndpointHost = 'mensura.cdn-apple.com';
const _configUri = 'https://mensura.cdn-apple.com/api/v1/gm/config';
const _userAgent =
    'networkQuality/194.80.3 CFNetwork/3860.400.51 Darwin/25.3.0';

Future<void> main(List<String> args) async {
  final options = _ProbeOptions.parse(args);
  if (options.showHelp) {
    stdout.write(_usage);
    return;
  }

  final config = await _fetchConfig(endpointHost: options.endpointHost);
  final resolvedIps = await _resolveHostIps(config.testEndpoint);

  stdout.writeln('endpoint: ${config.testEndpoint}');
  stdout.writeln('upload: ${config.uploadUri}');
  stdout.writeln('userAgent: $_userAgent');
  stdout.writeln('fixedIp: ${options.overrideIp ?? '-'}');
  stdout.writeln('verbose: ${options.verbose}');
  stdout.writeln(
    'responseTimeoutMs: ${options.responseTimeout.inMilliseconds}',
  );
  stdout.writeln(
    'resolvedIps: ${resolvedIps.isEmpty ? '-' : resolvedIps.join(', ')}',
  );

  if (options.mode == _ProbeMode.single || options.mode == _ProbeMode.both) {
    await _runProbe(
      config: config,
      options: options,
      modeLabel: 'single',
      connections: 1,
      chunkSize: 256 * 1024,
    );
  }

  if (options.mode == _ProbeMode.multi || options.mode == _ProbeMode.both) {
    await _runProbe(
      config: config,
      options: options,
      modeLabel: 'multi',
      connections: 4,
      chunkSize: 64 * 1024,
    );
  }
}

Future<void> _runProbe({
  required _ProbeConfig config,
  required _ProbeOptions options,
  required String modeLabel,
  required int connections,
  required int chunkSize,
}) async {
  final duration = options.duration;
  final responseTimeout = options.responseTimeout;

  final stopwatch = Stopwatch()..start();
  final ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {});
  final futures = <Future<_UploadProbeResult>>[];

  for (var i = 0; i < connections; i++) {
    futures.add(
      _sendUploadRequest(
        uploadUri: config.uploadUri,
        endpointHost: config.testEndpoint,
        overrideIp: options.overrideIp,
        duration: duration,
        responseTimeout: responseTimeout,
        chunkSize: chunkSize,
        verbose: options.verbose,
      ),
    );
  }

  try {
    final results = await Future.wait(futures);
    stopwatch.stop();
    ticker.cancel();

    final writtenBytes = results.fold<int>(
      0,
      (sum, value) => sum + value.bytes,
    );
    final uploadElapsed = _uploadElapsed(stopwatch.elapsed, duration);
    final mbps = _bytesToMbps(writtenBytes, uploadElapsed);
    final faultCount = results.where((result) => result.faulted).length;
    final serverBytes = results.fold<int>(
      0,
      (sum, result) => sum + (result.serverSample?.bytes ?? 0),
    );
    final serverBps = results.fold<int>(
      0,
      (sum, result) => sum + (result.serverSample?.bps ?? 0),
    );
    final details = results
        .map((result) => result.detail)
        .where((detail) => detail.isNotEmpty)
        .join(', ');
    final usedIps = results
        .map((result) => result.usedIp)
        .whereType<String>()
        .where((ip) => ip.isNotEmpty)
        .toSet()
        .join(', ');

    stdout.writeln(
      '$modeLabel: bytes=$writtenBytes elapsed=${stopwatch.elapsedMilliseconds}ms '
      'uploadWindowMs=${uploadElapsed.inMilliseconds} '
      'mbps=${mbps.toStringAsFixed(2)} faults=$faultCount '
      'serverBytes=${serverBytes == 0 ? '-' : serverBytes} '
      'serverMbps=${serverBps == 0 ? '-' : _bpsToMbps(serverBps).toStringAsFixed(2)} '
      'usedIps=[${usedIps.isEmpty ? '-' : usedIps}] details=[$details]',
    );
  } catch (error, stackTrace) {
    stopwatch.stop();
    ticker.cancel();
    stdout.writeln('$modeLabel: failed: $error');
    stderr.writeln(stackTrace);
  }
}

Future<_UploadProbeResult> _sendUploadRequest({
  required Uri uploadUri,
  required String endpointHost,
  required String? overrideIp,
  required Duration duration,
  required Duration responseTimeout,
  required int chunkSize,
  required bool verbose,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 12)
    ..userAgent = _userAgent;

  if (overrideIp != null && overrideIp.isNotEmpty) {
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final port = uri.port == 0 ? 443 : uri.port;
      final tcpTask = await Socket.startConnect(overrideIp, port);
      final secureSocket = tcpTask.socket.then(
        (socket) => SecureSocket.secure(
          socket,
          host: endpointHost,
          supportedProtocols: const <String>[],
        ),
      );

      return ConnectionTask.fromSocket(secureSocket, tcpTask.cancel);
    };
  }

  var uploadedBytes = 0;

  try {
    final request = await client.putUrl(uploadUri);
    request.bufferOutput = false;
    request.contentLength = -1;
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'zh-CN,zh-Hans;q=0.9',
    );
    request.headers.set('Upload-Draft-Interop-Version', '6');
    request.headers.set('Upload-Complete', '?1');

    await request.addStream(
      _countingUploadStream(
        duration: duration,
        chunkSize: chunkSize,
        onChunkConsumed: (bytes) {
          uploadedBytes += bytes;
        },
      ),
    );

    try {
      final requestUsedIp = request.connectionInfo?.remoteAddress.address;
      final responseStopwatch = Stopwatch()..start();
      final response = await request.close().timeout(responseTimeout);
      final usedIp =
          response.connectionInfo?.remoteAddress.address ?? requestUsedIp;
      final statusCode = response.statusCode;
      final responseHeaders = _formatHeaders(response.headers);
      if (response.statusCode >= 400) {
        final responseBody = await _readResponseBody(
          response: response,
          timeout: responseTimeout,
        );
        final serverSample = _parseServerSample(responseBody);
        if (verbose) {
          _printResponseDebug(
            prefix: 'upload',
            statusCode: statusCode,
            headers: responseHeaders,
            body: responseBody,
          );
        }
        return _UploadProbeResult(
          bytes: uploadedBytes,
          faulted: true,
          usedIp: usedIp,
          detail: _formatDetail(statusCode, responseBody, serverSample),
          serverSample: serverSample,
        );
      }
      final drainTimeout = responseTimeout - responseStopwatch.elapsed;
      if (drainTimeout <= Duration.zero) {
        throw TimeoutException('response timeout');
      }
      final responseBody = await _readResponseBody(
        response: response,
        timeout: drainTimeout,
      );
      final serverSample = _parseServerSample(responseBody);
      if (verbose) {
        _printResponseDebug(
          prefix: 'upload',
          statusCode: statusCode,
          headers: responseHeaders,
          body: responseBody,
        );
      }
      return _UploadProbeResult(
        bytes: uploadedBytes,
        faulted: false,
        usedIp: usedIp,
        detail: _formatDetail(statusCode, responseBody, serverSample),
        serverSample: serverSample,
      );
    } on TimeoutException {
      final usedIp = request.connectionInfo?.remoteAddress.address;
      request.abort();
      return _UploadProbeResult(
        bytes: uploadedBytes,
        faulted: false,
        usedIp: usedIp,
        detail: 'response timeout',
        serverSample: null,
      );
    } catch (error) {
      final usedIp = request.connectionInfo?.remoteAddress.address;
      request.abort();
      return _UploadProbeResult(
        bytes: uploadedBytes,
        faulted: true,
        usedIp: usedIp,
        detail: error.toString(),
        serverSample: null,
      );
    }
  } finally {
    client.close(force: true);
  }
}

Future<String> _readResponseBody({
  required HttpClientResponse response,
  required Duration timeout,
}) async {
  final chunks = <int>[];
  await for (final chunk in response.timeout(timeout)) {
    if (chunks.length < 4096) {
      final remaining = 4096 - chunks.length;
      chunks.addAll(chunk.length <= remaining ? chunk : chunk.take(remaining));
    }
  }
  return utf8.decode(chunks, allowMalformed: true);
}

Map<String, List<String>> _formatHeaders(HttpHeaders headers) {
  final formatted = <String, List<String>>{};
  headers.forEach((name, values) {
    formatted[name] = values;
  });
  return formatted;
}

void _printResponseDebug({
  required String prefix,
  required int statusCode,
  required Map<String, List<String>> headers,
  required String body,
}) {
  stdout.writeln('$prefix response status: $statusCode');
  stdout.writeln('$prefix response headers: ${jsonEncode(headers)}');
  stdout.writeln('$prefix response body: ${_compact(body)}');
}

String _compact(String value) {
  final compacted = value
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  if (compacted.isEmpty) {
    return '-';
  }
  return compacted.length <= 600
      ? compacted
      : '${compacted.substring(0, 600)}...';
}

Stream<List<int>> _countingUploadStream({
  required Duration duration,
  required int chunkSize,
  required void Function(int bytes) onChunkConsumed,
}) async* {
  final stopwatch = Stopwatch()..start();
  final chunk = Uint8List(chunkSize);

  while (stopwatch.elapsed < duration) {
    onChunkConsumed(chunk.length);
    yield chunk;
  }
}

double _bytesToMbps(int bytes, Duration elapsed) {
  if (bytes <= 0 || elapsed.inMicroseconds <= 0) {
    return 0;
  }
  return bytes * 8 / elapsed.inMicroseconds;
}

double _bpsToMbps(int bps) {
  if (bps <= 0) {
    return 0;
  }
  return bps * 8 / 1000000;
}

_ServerUploadSample? _parseServerSample(String body) {
  try {
    final data = jsonDecode(body) as Map<String, dynamic>;
    final durationMs = (data['DurationMs'] as num?)?.toInt();
    final bytes = (data['Bytes'] as num?)?.toInt();
    final bps = (data['BPS'] as num?)?.toInt();
    if (durationMs == null || bytes == null || bps == null) {
      return null;
    }
    return _ServerUploadSample(durationMs: durationMs, bytes: bytes, bps: bps);
  } catch (_) {
    return null;
  }
}

String _formatDetail(
  int statusCode,
  String responseBody,
  _ServerUploadSample? serverSample,
) {
  if (serverSample == null) {
    return 'http $statusCode body=${_compact(responseBody)}';
  }

  return 'http $statusCode serverBytes=${serverSample.bytes} '
      'serverDurationMs=${serverSample.durationMs} '
      'serverMbps=${_bpsToMbps(serverSample.bps).toStringAsFixed(2)}';
}

Duration _uploadElapsed(Duration elapsed, Duration uploadWindow) {
  if (elapsed <= Duration.zero) {
    return const Duration(microseconds: 1);
  }
  return elapsed > uploadWindow ? uploadWindow : elapsed;
}

Future<_ProbeConfig> _fetchConfig({required String endpointHost}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 12)
    ..userAgent = _userAgent;

  try {
    final request = await client.getUrl(Uri.parse(_configUri));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final urls = data['urls'] as Map<String, dynamic>? ?? const {};
    final upload = Uri.parse(
      urls['https_upload_url'] as String? ?? urls['upload_url'] as String,
    );

    return _ProbeConfig(
      testEndpoint: endpointHost,
      uploadUri: upload.replace(host: endpointHost),
    );
  } finally {
    client.close(force: true);
  }
}

const _usage =
    '''
Usage:
  dart tool/upload_probe.dart [options]

Options:
  --ip <address>          Force every upload connection to this IP.
  --endpoint <host>       TLS/SNI host to test. Default: $_defaultEndpointHost
  --mode <single|multi|both>
                          Upload mode. Default: both
  --duration <seconds>    Upload window in seconds. Default: 8
  --response-timeout <seconds>
                          Time to wait for the HTTP response after upload.
                          Default: 2
  --verbose               Print upload response headers and body.
  --help                  Show this help.

macOS examples:
  ../flutter/bin/dart tool/upload_probe.dart --ip <test-ip> --mode multi
  ../flutter/bin/dart tool/upload_probe.dart --ip <test-ip> --mode both --duration 8 --response-timeout 2
''';

enum _ProbeMode { single, multi, both }

class _ProbeOptions {
  const _ProbeOptions({
    required this.mode,
    required this.duration,
    required this.responseTimeout,
    required this.endpointHost,
    required this.overrideIp,
    required this.verbose,
    required this.showHelp,
  });

  factory _ProbeOptions.parse(List<String> args) {
    var mode = _ProbeMode.both;
    var duration = const Duration(seconds: 8);
    var responseTimeout = const Duration(seconds: 2);
    var endpointHost = _defaultEndpointHost;
    String? overrideIp;
    var verbose = false;
    var showHelp = false;

    String readValue(int index, String option) {
      final valueIndex = index + 1;
      if (valueIndex >= args.length || args[valueIndex].startsWith('--')) {
        throw ArgumentError('Missing value for $option');
      }
      return args[valueIndex];
    }

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      switch (arg) {
        case '--help':
        case '-h':
          showHelp = true;
        case '--verbose':
          verbose = true;
        case '--ip':
          overrideIp = readValue(index, arg).trim();
          index++;
        case '--endpoint':
          endpointHost = readValue(index, arg).trim();
          index++;
        case '--mode':
          final value = readValue(index, arg).trim().toLowerCase();
          mode = switch (value) {
            'single' => _ProbeMode.single,
            'multi' => _ProbeMode.multi,
            'both' => _ProbeMode.both,
            _ => throw ArgumentError('Invalid --mode: $value'),
          };
          index++;
        case '--duration':
          final seconds = int.tryParse(readValue(index, arg));
          if (seconds == null || seconds <= 0) {
            throw ArgumentError('Invalid --duration: ${args[index + 1]}');
          }
          duration = Duration(seconds: seconds);
          index++;
        case '--response-timeout':
          final seconds = int.tryParse(readValue(index, arg));
          if (seconds == null || seconds <= 0) {
            throw ArgumentError(
              'Invalid --response-timeout: ${args[index + 1]}',
            );
          }
          responseTimeout = Duration(seconds: seconds);
          index++;
        default:
          throw ArgumentError('Unknown option: $arg');
      }
    }

    return _ProbeOptions(
      mode: mode,
      duration: duration,
      responseTimeout: responseTimeout,
      endpointHost: endpointHost,
      overrideIp: overrideIp,
      verbose: verbose,
      showHelp: showHelp,
    );
  }

  final _ProbeMode mode;
  final Duration duration;
  final Duration responseTimeout;
  final String endpointHost;
  final String? overrideIp;
  final bool verbose;
  final bool showHelp;
}

Future<List<String>> _resolveHostIps(String host) async {
  try {
    final addresses = await InternetAddress.lookup(host);
    return addresses.map((address) => address.address).toSet().toList();
  } catch (_) {
    return const [];
  }
}

class _ProbeConfig {
  const _ProbeConfig({required this.testEndpoint, required this.uploadUri});

  final String testEndpoint;
  final Uri uploadUri;
}

class _UploadProbeResult {
  const _UploadProbeResult({
    required this.bytes,
    required this.faulted,
    required this.usedIp,
    required this.detail,
    required this.serverSample,
  });

  final int bytes;
  final bool faulted;
  final String? usedIp;
  final String detail;
  final _ServerUploadSample? serverSample;
}

class _ServerUploadSample {
  const _ServerUploadSample({
    required this.durationMs,
    required this.bytes,
    required this.bps,
  });

  final int durationMs;
  final int bytes;
  final int bps;
}
