import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'speed_test_models.dart';
import 'speed_test_network_binding.dart';

class SpeedTestService {
  static const String _userAgent =
      'networkQuality/194.80.3 CFNetwork/3860.400.51 Darwin/25.3.0';
  static final Uri _configUri = Uri.parse(
    'https://mensura.cdn-apple.com/api/v1/gm/config',
  );
  static const String _ipApiFields =
      'status,message,query,country,regionName,city,isp,org,as,asname';
  static const Duration _downloadDuration = Duration(seconds: 8);
  static const Duration _uploadDuration = Duration(seconds: 8);
  static const Duration _uploadGraceDuration = Duration(seconds: 2);
  static const Duration _uploadProgressInterval = Duration(milliseconds: 500);

  SpeedTestService({SpeedTestNetworkBinding? networkBinding})
    : _uploadDurationOverride = null,
      _uploadGraceDurationOverride = null,
      _resolveHostWithDohOverride = null,
      _networkBinding = networkBinding ?? SpeedTestNetworkBinding();

  @visibleForTesting
  SpeedTestService.test({
    Duration? uploadDuration,
    Duration? uploadGraceDuration,
    Future<DohResolution> Function(String host, DohProvider provider)?
    resolveHostWithDoh,
    SpeedTestNetworkBinding? networkBinding,
  }) : _uploadDurationOverride = uploadDuration,
       _uploadGraceDurationOverride = uploadGraceDuration,
       _resolveHostWithDohOverride = resolveHostWithDoh,
       _networkBinding = networkBinding ?? NoopSpeedTestNetworkBinding();

  final List<HttpClient> _activeClients = <HttpClient>[];
  final Duration? _uploadDurationOverride;
  final Duration? _uploadGraceDurationOverride;
  final Future<DohResolution> Function(String host, DohProvider provider)?
  _resolveHostWithDohOverride;
  final SpeedTestNetworkBinding _networkBinding;
  bool _cancelRequested = false;

  Duration get _configuredUploadDuration =>
      _uploadDurationOverride ?? _uploadDuration;

  Duration get _configuredUploadGraceDuration =>
      _uploadGraceDurationOverride ?? _uploadGraceDuration;

  Future<SpeedTestBootstrap> bootstrap({
    required DohProvider provider,
    List<String> customHosts = const [],
  }) async {
    _cancelRequested = false;
    final config = await _fetchConfig();

    final hostSet = <String>{defaultSpeedTestEndpointHost};

    for (final host in customHosts) {
      final normalized = normalizeHost(host);
      if (normalized != null && normalized.isNotEmpty) {
        hostSet.add(normalized);
      }
    }

    final endpoints = <SpeedTestEndpointOption>[];
    for (final host in hostSet) {
      final resolution = await _resolveHostWithDoh(host, provider);
      endpoints.add(
        SpeedTestEndpointOption(
          id: host,
          label: switch (host) {
            defaultSpeedTestEndpointHost => '默认入口节点',
            _ => '自定义节点',
          },
          host: host,
          description: switch (host) {
            defaultSpeedTestEndpointHost => '使用 Apple 默认入口域名测速',
            _ => '用户手动添加的测速节点',
          },
          resolution: resolution,
          isCustom: host != defaultSpeedTestEndpointHost,
        ),
      );
    }

    final sortedEndpoints = endpoints.toList()
      ..sort((a, b) {
        final priorityA = switch (a.label) {
          '默认入口节点' => 0,
          _ => 2,
        };
        final priorityB = switch (b.label) {
          '默认入口节点' => 0,
          _ => 2,
        };

        if (priorityA != priorityB) {
          return priorityA.compareTo(priorityB);
        }

        return a.host.compareTo(b.host);
      });

    return SpeedTestBootstrap(
      config: config,
      endpoints: sortedEndpoints,
      provider: provider,
    );
  }

  Future<SpeedTestResult> run({
    required SpeedTestOptions options,
    required void Function(SpeedTestProgress progress) onProgress,
  }) async {
    _cancelRequested = false;
    final networkBindingLease = options.bypassVpn
        ? await _networkBinding.bindToNonVpnNetwork()
        : SpeedTestNetworkBindingLease.noop();

    try {
      onProgress(
        SpeedTestProgress(
          phase: SpeedTestPhase.preparing,
          statusMessage: options.bypassVpn && networkBindingLease.didBind
              ? '已绕过 VPN · ${networkBindingLease.diagnostic ?? '非 VPN 网络'}'
              : '正在获取 Apple 测速配置',
          mode: options.mode,
          phaseProgress: 0.15,
          overallProgress: 0.03,
        ),
      );

      final config = (await _fetchConfig()).copyWithEndpoint(
        sanitizeEndpointHost(options.endpointHost),
      );
      final preferredAutoIp =
          options.selectedIp ??
          await _resolvePreferredAutoIp(
            config.testEndpoint,
            options.dohProvider,
          );
      _throwIfCancelled();
      final warmUpUsedIp = await _warmUp(config, preferredAutoIp);
      _throwIfCancelled();

      onProgress(
        SpeedTestProgress(
          phase: SpeedTestPhase.preparing,
          statusMessage: options.selectedIp != null
              ? '测速节点已就绪，固定 IP ${options.selectedIp}'
              : (preferredAutoIp != null
                    ? '测速节点已就绪，自动使用${options.dohProvider.label} DoH IP $preferredAutoIp'
                    : '测速节点已就绪'),
          endpoint: sanitizeEndpointHost(config.testEndpoint),
          usedIp: warmUpUsedIp ?? preferredAutoIp,
          mode: options.mode,
          phaseProgress: 1,
          overallProgress: 0.08,
        ),
      );

      final downloadSample = await _measureDownload(
        config: config,
        mode: options.mode,
        selectedIp: preferredAutoIp,
        onProgress: onProgress,
      );

      _throwIfCancelled();

      final uploadSample = await _measureUpload(
        config: config,
        mode: options.mode,
        selectedIp: preferredAutoIp,
        downloadMbps: downloadSample.mbps,
        downloadedBytes: downloadSample.bytes,
        onProgress: onProgress,
      );
      _throwIfCancelled();

      return SpeedTestResult(
        endpoint: sanitizeEndpointHost(config.testEndpoint),
        mode: options.mode,
        downloadMbps: downloadSample.mbps,
        uploadMbps: uploadSample.mbps,
        downloadedBytes: downloadSample.bytes,
        uploadedBytes: uploadSample.bytes,
        finishedAt: DateTime.now(),
        usedIp:
            downloadSample.usedIp ??
            uploadSample.usedIp ??
            warmUpUsedIp ??
            preferredAutoIp,
      );
    } finally {
      await networkBindingLease.restore();
    }
  }

  void cancel() {
    _cancelRequested = true;
    for (final client in _activeClients) {
      client.close(force: true);
    }
    _activeClients.clear();
  }

  @visibleForTesting
  Future<SpeedTestResult> measureUploadForTesting({
    required SpeedTestConfig config,
    required SpeedTestMode mode,
    String? selectedIp,
    double downloadMbps = 0,
    int downloadedBytes = 0,
    void Function(SpeedTestProgress progress)? onProgress,
  }) async {
    _cancelRequested = false;
    final sample = await _measureUpload(
      config: config,
      mode: mode,
      selectedIp: selectedIp,
      downloadMbps: downloadMbps,
      downloadedBytes: downloadedBytes,
      onProgress: onProgress ?? (_) {},
    );

    return SpeedTestResult(
      endpoint: sanitizeEndpointHost(config.testEndpoint),
      mode: mode,
      downloadMbps: downloadMbps,
      uploadMbps: sample.mbps,
      downloadedBytes: downloadedBytes,
      uploadedBytes: sample.bytes,
      finishedAt: DateTime.now(),
      usedIp: sample.usedIp,
    );
  }

  @visibleForTesting
  Future<String?> resolvePreferredAutoIpForTesting(
    String endpointHost,
    DohProvider provider,
  ) {
    return _resolvePreferredAutoIp(endpointHost, provider);
  }

  static String? normalizeHost(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(candidate);
    final host = uri?.host.trim();
    if (host == null || host.isEmpty) {
      return null;
    }

    final normalized = host.toLowerCase();
    if (_isValidIpAddress(normalized) || _isValidHostname(normalized)) {
      return normalized;
    }

    return null;
  }

  static bool _isValidIpAddress(String value) {
    return InternetAddress.tryParse(value) != null;
  }

  static bool _isValidHostname(String value) {
    if (value.length > 253 || value.startsWith('.') || value.endsWith('.')) {
      return false;
    }

    final labels = value.split('.');
    if (labels.length < 2) {
      return false;
    }

    final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    for (final label in labels) {
      if (!labelPattern.hasMatch(label)) {
        return false;
      }
    }

    return true;
  }

  Future<SpeedTestConfig> _fetchConfig() async {
    final client = _createClient();
    try {
      final request = await client.getUrl(_configUri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      return SpeedTestConfig.fromJson(data);
    } finally {
      _closeClient(client);
    }
  }

  Future<TargetIpInfo?> fetchTargetIpInfo({required String? query}) async {
    final normalized = query?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }

    final client = _createClient();
    try {
      final uri = Uri.parse(
        'http://ip-api.com/json/$normalized?fields=$_ipApiFields&lang=zh-CN',
      );
      final request = await client.getUrl(uri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      if ((json['status'] as String?) != 'success') {
        return null;
      }
      return TargetIpInfo.fromJson(json);
    } catch (_) {
      return null;
    } finally {
      _closeClient(client);
    }
  }

  Future<String?> _warmUp(SpeedTestConfig config, String? selectedIp) async {
    final client = _createClient(
      overrideHost: config.testEndpoint,
      overrideIp: selectedIp,
    );
    try {
      HttpClientResponse response;
      try {
        final request = await client.getUrl(config.smallDownloadUri);
        response = await request.close();
      } catch (_) {
        final request = await client.getUrl(config.fallbackSmallDownloadUri);
        response = await request.close();
      }

      await response.first;
      return response.connectionInfo?.remoteAddress.address ?? selectedIp;
    } finally {
      _closeClient(client);
    }
  }

  Future<String?> _resolvePreferredAutoIp(
    String endpointHost,
    DohProvider provider,
  ) async {
    if (_isValidIpAddress(endpointHost)) {
      return endpointHost;
    }

    final resolution = await _resolveHostWithDoh(endpointHost, provider);
    return resolution.ipv4.firstOrNull ?? resolution.ipv6.firstOrNull;
  }

  Future<_ThroughputSample> _measureDownload({
    required SpeedTestConfig config,
    required SpeedTestMode mode,
    required String? selectedIp,
    required void Function(SpeedTestProgress progress) onProgress,
  }) async {
    const duration = _downloadDuration;
    final stopwatch = Stopwatch()..start();
    final completer = Completer<_ThroughputSample>();
    final subscriptions = <StreamSubscription<List<int>>>[];
    final clients = <HttpClient>[];
    var totalBytes = 0;
    var completedWorkers = 0;
    Object? firstError;
    StackTrace? firstStackTrace;
    Timer? ticker;
    String? resolvedIp;

    void completeWithSample() {
      if (completer.isCompleted) {
        return;
      }

      ticker?.cancel();
      stopwatch.stop();
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
      for (final client in clients) {
        _closeClient(client);
      }

      if (_cancelRequested) {
        completer.completeError(const SpeedTestCancelled());
        return;
      }

      if (totalBytes == 0 && firstError != null) {
        completer.completeError(firstError!, firstStackTrace);
        return;
      }

      completer.complete(
        _ThroughputSample(
          mbps: _bytesToMbps(totalBytes, stopwatch.elapsed),
          bytes: totalBytes,
          usedIp: resolvedIp ?? selectedIp,
        ),
      );
    }

    ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_cancelRequested) {
        ticker?.cancel();
        return;
      }

      final phaseProgress = _progressForElapsed(stopwatch.elapsed, duration);
      final currentMbps = _bytesToMbps(totalBytes, stopwatch.elapsed);
      final endpointDisplay = sanitizeEndpointHost(config.testEndpoint);

      onProgress(
        SpeedTestProgress(
          phase: SpeedTestPhase.downloading,
          statusMessage: '下载测速中 · ${mode.label}',
          endpoint: endpointDisplay,
          usedIp: resolvedIp ?? selectedIp,
          currentMbps: currentMbps,
          downloadMbps: currentMbps,
          downloadedBytes: totalBytes,
          mode: mode,
          phaseProgress: phaseProgress,
          overallProgress: 0.08 + (phaseProgress * 0.46),
        ),
      );

      if (stopwatch.elapsed >= duration) {
        completeWithSample();
      }
    });

    for (var index = 0; index < mode.connections; index++) {
      unawaited(() async {
        final client = _createClient(
          overrideHost: config.testEndpoint,
          overrideIp: selectedIp,
        );
        clients.add(client);

        try {
          final response = await _openDownloadResponse(client, config);
          resolvedIp ??=
              response.connectionInfo?.remoteAddress.address ?? selectedIp;
          late final StreamSubscription<List<int>> subscription;
          subscription = response.listen(
            (chunk) {
              totalBytes += chunk.length;
              if (stopwatch.elapsed >= duration) {
                subscription.cancel();
              }
            },
            onDone: () {
              completedWorkers++;
              if (completedWorkers >= mode.connections) {
                completeWithSample();
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              firstError ??= error;
              firstStackTrace ??= stackTrace;
              completedWorkers++;
              if (completedWorkers >= mode.connections) {
                completeWithSample();
              }
            },
            cancelOnError: false,
          );

          subscriptions.add(subscription);
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
          completedWorkers++;
          if (completedWorkers >= mode.connections) {
            completeWithSample();
          }
        }
      }());
    }

    final sample = await completer.future;
    onProgress(
      SpeedTestProgress(
        phase: SpeedTestPhase.downloading,
        statusMessage: '下载测速完成',
        endpoint: sanitizeEndpointHost(config.testEndpoint),
        usedIp: sample.usedIp,
        currentMbps: sample.mbps,
        downloadMbps: sample.mbps,
        downloadedBytes: sample.bytes,
        mode: mode,
        phaseProgress: 1,
        overallProgress: 0.54,
      ),
    );
    return sample;
  }

  Future<_ThroughputSample> _measureUpload({
    required SpeedTestConfig config,
    required SpeedTestMode mode,
    required String? selectedIp,
    required double downloadMbps,
    required int downloadedBytes,
    required void Function(SpeedTestProgress progress) onProgress,
  }) async {
    final duration = _configuredUploadDuration;
    final responseTimeout = _configuredUploadGraceDuration;
    final uploadWriteTimeout = duration + responseTimeout;
    final stopwatch = Stopwatch()..start();
    final completer = Completer<_ThroughputSample>();
    final clients = <HttpClient>[];
    var totalUploadedBytes = 0;
    var uploadFaultCount = 0;
    var finishedWorkers = 0;
    Object? firstError;
    StackTrace? firstStackTrace;
    Timer? ticker;
    String? resolvedIp;

    Future<void> completeWithSample() async {
      if (completer.isCompleted) {
        return;
      }

      ticker?.cancel();
      stopwatch.stop();
      for (final client in clients) {
        _closeClient(client);
      }

      if (_cancelRequested) {
        completer.completeError(const SpeedTestCancelled());
        return;
      }

      if (uploadFaultCount >= mode.connections) {
        completer.completeError(
          StateError('Upload failed after $uploadFaultCount network faults'),
        );
        return;
      }

      if (totalUploadedBytes == 0 && firstError != null) {
        completer.completeError(firstError!, firstStackTrace);
        return;
      }

      final effectiveElapsed = _uploadElapsed(stopwatch.elapsed, duration);
      completer.complete(
        _ThroughputSample(
          mbps: _bytesToMbps(totalUploadedBytes, effectiveElapsed),
          bytes: totalUploadedBytes,
          usedIp: resolvedIp ?? selectedIp,
        ),
      );
    }

    ticker = Timer.periodic(_uploadProgressInterval, (_) {
      if (_cancelRequested) {
        ticker?.cancel();
        return;
      }
      final displayElapsed = _uploadElapsed(stopwatch.elapsed, duration);
      final phaseProgress = _progressForElapsed(displayElapsed, duration);
      final currentMbps = _bytesToMbps(totalUploadedBytes, displayElapsed);
      onProgress(
        _uploadProgress(
          config: config,
          mode: mode,
          selectedIp: resolvedIp ?? selectedIp,
          downloadMbps: downloadMbps,
          downloadedBytes: downloadedBytes,
          uploadedBytes: totalUploadedBytes,
          mbps: currentMbps,
          statusMessage: '上传测速中 · ${mode.label}',
          phaseProgress: phaseProgress,
          overallProgress: 0.54 + (phaseProgress * 0.44),
        ),
      );

      if (finishedWorkers >= mode.connections) {
        unawaited(completeWithSample());
      }
    });

    for (var index = 0; index < mode.connections; index++) {
      unawaited(() async {
        final client = _createClient(
          overrideHost: config.testEndpoint,
          overrideIp: selectedIp,
        );
        clients.add(client);

        try {
          final uploadResult = await _sendUploadRequest(
            client: client,
            config: config,
            stopwatch: stopwatch,
            duration: duration,
            uploadWriteTimeout: uploadWriteTimeout,
            responseTimeout: responseTimeout,
            mode: mode,
            onChunkConsumed: (bytes) {
              totalUploadedBytes += bytes;
            },
          );

          resolvedIp ??= uploadResult.usedIp ?? selectedIp;

          if (uploadResult.faulted) {
            uploadFaultCount++;
          }

          if (uploadResult.bytes <= 0 && stopwatch.elapsed < duration) {
            firstError ??= StateError('上传未发送任何数据');
          }
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        } finally {
          finishedWorkers++;
          if (finishedWorkers >= mode.connections) {
            await completeWithSample();
          }
        }
      }());
    }

    final sample = await completer.future;
    onProgress(
      _uploadProgress(
        config: config,
        mode: mode,
        selectedIp: sample.usedIp,
        downloadMbps: downloadMbps,
        downloadedBytes: downloadedBytes,
        uploadedBytes: sample.bytes,
        mbps: sample.mbps,
        statusMessage: uploadFaultCount > 0
            ? '上传测速完成 · $uploadFaultCount 次网络波动'
            : '上传测速完成',
        phaseProgress: 1,
        overallProgress: 0.98,
      ),
    );
    return sample;
  }

  SpeedTestProgress _uploadProgress({
    required SpeedTestConfig config,
    required SpeedTestMode mode,
    required String? selectedIp,
    required double downloadMbps,
    required int downloadedBytes,
    required int uploadedBytes,
    required double mbps,
    required String statusMessage,
    required double phaseProgress,
    required double overallProgress,
  }) {
    return SpeedTestProgress(
      phase: SpeedTestPhase.uploading,
      statusMessage: statusMessage,
      endpoint: sanitizeEndpointHost(config.testEndpoint),
      usedIp: selectedIp,
      currentMbps: mbps,
      downloadMbps: downloadMbps,
      uploadMbps: mbps,
      downloadedBytes: downloadedBytes,
      uploadedBytes: uploadedBytes,
      mode: mode,
      phaseProgress: phaseProgress,
      overallProgress: overallProgress,
    );
  }

  Future<_UploadRequestResult> _sendUploadRequest({
    required HttpClient client,
    required SpeedTestConfig config,
    required Stopwatch stopwatch,
    required Duration duration,
    required Duration uploadWriteTimeout,
    required Duration responseTimeout,
    required SpeedTestMode mode,
    required void Function(int bytes) onChunkConsumed,
  }) async {
    final request = await _openUploadRequest(client, config);
    request.bufferOutput = false;
    request.contentLength = -1;
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'zh-CN,zh-Hans;q=0.9',
    );
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set('Upload-Draft-Interop-Version', '6');
    request.headers.set('Upload-Complete', '?1');
    final profile = _uploadWriteProfileFor(mode);
    var consumedBytes = 0;

    try {
      await request
          .addStream(
            _countingUploadStream(
              stopwatch: stopwatch,
              duration: duration,
              chunkSize: profile.chunkSize,
              shouldStop: () => _cancelRequested,
              onChunkConsumed: (bytes) {
                consumedBytes += bytes;
                onChunkConsumed(bytes);
              },
            ),
          )
          .timeout(
            uploadWriteTimeout,
            onTimeout: () {
              request.abort();
              throw TimeoutException('上传写入超时');
            },
          );

      if (_cancelRequested) {
        request.abort();
        return const _UploadRequestResult(
          bytes: 0,
          usedIp: null,
          faulted: false,
        );
      }

      final responseStopwatch = Stopwatch()..start();
      final response = await request.close().timeout(responseTimeout);
      final usedIp = response.connectionInfo?.remoteAddress.address;
      if (response.statusCode >= 400) {
        return _UploadRequestResult(
          bytes: consumedBytes,
          usedIp: usedIp,
          faulted: true,
        );
      }

      final drainTimeout = responseTimeout - responseStopwatch.elapsed;
      if (drainTimeout <= Duration.zero) {
        throw TimeoutException('上传响应超时');
      }
      await response.drain<void>().timeout(drainTimeout);

      return _UploadRequestResult(
        bytes: consumedBytes,
        usedIp: usedIp,
        faulted: false,
      );
    } on TimeoutException {
      final usedIp = request.connectionInfo?.remoteAddress.address;
      request.abort();
      return _UploadRequestResult(
        bytes: consumedBytes,
        usedIp: usedIp,
        faulted: false,
      );
    } catch (_) {
      if (_cancelRequested) {
        request.abort();
        return const _UploadRequestResult(
          bytes: 0,
          usedIp: null,
          faulted: false,
        );
      }
      final usedIp = request.connectionInfo?.remoteAddress.address;
      request.abort();
      return _UploadRequestResult(
        bytes: consumedBytes,
        usedIp: usedIp,
        faulted: true,
      );
    }
  }

  Future<HttpClientResponse> _openDownloadResponse(
    HttpClient client,
    SpeedTestConfig config,
  ) async {
    try {
      final request = await client.getUrl(config.largeDownloadUri);
      return await request.close();
    } catch (_) {
      final request = await client.getUrl(config.fallbackLargeDownloadUri);
      return await request.close();
    }
  }

  Future<HttpClientRequest> _openUploadRequest(
    HttpClient client,
    SpeedTestConfig config,
  ) async {
    try {
      return await client.putUrl(config.uploadUri);
    } catch (_) {
      return client.putUrl(config.fallbackUploadUri);
    }
  }

  Future<DohResolution> _resolveHostWithDoh(
    String host,
    DohProvider provider,
  ) async {
    if (_resolveHostWithDohOverride case final resolver?) {
      return resolver(host, provider);
    }

    final ipv4 = await _queryDoh(host, 'A', provider);
    final ipv6 = await _queryDoh(host, 'AAAA', provider);

    if (ipv4.isEmpty && ipv6.isEmpty) {
      try {
        final addresses = await InternetAddress.lookup(host);
        return DohResolution(
          host: host,
          ipv4: addresses
              .where((item) => item.type == InternetAddressType.IPv4)
              .map((item) => item.address)
              .toSet()
              .toList(),
          ipv6: addresses
              .where((item) => item.type == InternetAddressType.IPv6)
              .map((item) => item.address)
              .toSet()
              .toList(),
          resolver: 'system-fallback',
          resolvedAt: DateTime.now(),
        );
      } catch (_) {
        return DohResolution(
          host: host,
          ipv4: const [],
          ipv6: const [],
          resolver: provider.resolverName,
          resolvedAt: DateTime.now(),
        );
      }
    }

    return DohResolution(
      host: host,
      ipv4: ipv4,
      ipv6: ipv6,
      resolver: provider.resolverName,
      resolvedAt: DateTime.now(),
    );
  }

  Future<List<String>> _queryDoh(
    String host,
    String type,
    DohProvider provider,
  ) async {
    final client = _createClient();
    try {
      final uri = _dohUri(
        provider,
      ).replace(queryParameters: <String, String>{'name': host, 'type': type});
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final answers = json['Answer'] as List<dynamic>? ?? const [];

      return answers
          .map((item) => item as Map<String, dynamic>)
          .where((item) {
            final answerType = item['type'];
            return (type == 'A' && answerType == 1) ||
                (type == 'AAAA' && answerType == 28);
          })
          .map((item) => item['data'] as String? ?? '')
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList();
    } catch (_) {
      return const [];
    } finally {
      _closeClient(client);
    }
  }

  Uri _dohUri(DohProvider provider) => switch (provider) {
    DohProvider.google => Uri.parse('https://dns.google/resolve'),
    DohProvider.cloudflare => Uri.parse('https://cloudflare-dns.com/dns-query'),
    DohProvider.aliyun => Uri.parse('https://dns.alidns.com/resolve'),
  };

  HttpClient _createClient({String? overrideHost, String? overrideIp}) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 12)
      ..userAgent = _userAgent;

    if (overrideHost != null && overrideIp != null && overrideIp.isNotEmpty) {
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        final port = uri.port == 0 ? 443 : uri.port;
        final tcpTask = await Socket.startConnect(overrideIp, port);
        final secureSocket = tcpTask.socket.then(
          (socket) => SecureSocket.secure(
            socket,
            host: overrideHost,
            supportedProtocols: const <String>[],
          ),
        );

        return ConnectionTask.fromSocket(secureSocket, tcpTask.cancel);
      };
    }

    _activeClients.add(client);
    return client;
  }

  void _closeClient(HttpClient client) {
    client.close(force: true);
    _activeClients.remove(client);
  }

  void _throwIfCancelled() {
    if (_cancelRequested) {
      throw const SpeedTestCancelled();
    }
  }

  double _bytesToMbps(int bytes, Duration elapsed) {
    if (bytes <= 0 || elapsed.inMicroseconds <= 0) {
      return 0;
    }

    return bytes * 8 / elapsed.inMicroseconds;
  }

  Duration _uploadElapsed(Duration elapsed, Duration uploadWindow) {
    if (elapsed <= Duration.zero) {
      return const Duration(microseconds: 1);
    }
    return elapsed > uploadWindow ? uploadWindow : elapsed;
  }

  double _progressForElapsed(Duration elapsed, Duration total) {
    if (total.inMicroseconds <= 0) {
      return 0;
    }

    final raw = elapsed.inMicroseconds / total.inMicroseconds;
    return raw.clamp(0.0, 1.0);
  }

  Stream<List<int>> _countingUploadStream({
    required Stopwatch stopwatch,
    required Duration duration,
    required int chunkSize,
    required bool Function() shouldStop,
    required void Function(int bytes) onChunkConsumed,
  }) async* {
    final chunk = Uint8List(chunkSize);
    while (!shouldStop() && stopwatch.elapsed < duration) {
      onChunkConsumed(chunk.length);
      yield chunk;
    }
  }

  _UploadWriteProfile _uploadWriteProfileFor(SpeedTestMode mode) {
    return switch (mode) {
      SpeedTestMode.singleThread => const _UploadWriteProfile(
        chunkSize: 256 * 1024,
      ),
      SpeedTestMode.multiThread => const _UploadWriteProfile(
        chunkSize: 64 * 1024,
      ),
    };
  }
}

class _ThroughputSample {
  const _ThroughputSample({
    required this.mbps,
    required this.bytes,
    required this.usedIp,
  });

  final double mbps;
  final int bytes;
  final String? usedIp;
}

class _UploadRequestResult {
  const _UploadRequestResult({
    required this.bytes,
    required this.usedIp,
    required this.faulted,
  });

  final int bytes;
  final String? usedIp;
  final bool faulted;
}

class _UploadWriteProfile {
  const _UploadWriteProfile({required this.chunkSize});

  final int chunkSize;
}
