import 'dart:io';

String sanitizeEndpointHost(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }

  final withoutIpSuffix = trimmed.replaceAll(
    RegExp(r'(?:\s*\[[^\[\]]+\])+\s*$'),
    '',
  );
  if (!_looksLikeEndpointHost(withoutIpSuffix)) {
    return withoutIpSuffix.trim();
  }

  final candidate = withoutIpSuffix.contains('://')
      ? withoutIpSuffix
      : 'https://$withoutIpSuffix';
  final uri = Uri.tryParse(candidate);
  final host = uri?.host.trim();
  if (host != null && host.isNotEmpty) {
    return host.toLowerCase();
  }

  return withoutIpSuffix.trim();
}

bool _looksLikeEndpointHost(String value) {
  final candidate = value.trim();
  if (candidate.isEmpty) {
    return false;
  }

  if (candidate.contains('://')) {
    return true;
  }

  if (InternetAddress.tryParse(candidate) != null) {
    return true;
  }

  return RegExp(r'^[a-z0-9.-]+$', caseSensitive: false).hasMatch(candidate) &&
      candidate.contains('.');
}

enum SpeedTestPhase {
  idle,
  preparing,
  downloading,
  uploading,
  completed,
  error,
  cancelled,
}

enum SpeedTestMode { singleThread, multiThread }

extension SpeedTestModeX on SpeedTestMode {
  String get label => switch (this) {
    SpeedTestMode.singleThread => '单线程',
    SpeedTestMode.multiThread => '多线程',
  };

  String get subtitle => switch (this) {
    SpeedTestMode.singleThread => '单连接，更适合看单路质量',
    SpeedTestMode.multiThread => '4 连接聚合，更接近跑满带宽',
  };

  int get connections => switch (this) {
    SpeedTestMode.singleThread => 1,
    SpeedTestMode.multiThread => 4,
  };
}

enum DohProvider { google, cloudflare, aliyun }

extension DohProviderX on DohProvider {
  String get label => switch (this) {
    DohProvider.google => 'Google',
    DohProvider.cloudflare => 'Cloudflare',
    DohProvider.aliyun => '阿里云',
  };

  String get resolverName => switch (this) {
    DohProvider.google => 'dns.google',
    DohProvider.cloudflare => 'cloudflare-dns.com',
    DohProvider.aliyun => 'dns.alidns.com',
  };
}

class SpeedTestConfig {
  const SpeedTestConfig({
    required this.testEndpoint,
    required this.smallDownloadUri,
    required this.largeDownloadUri,
    required this.uploadUri,
    required this.fallbackSmallDownloadUri,
    required this.fallbackLargeDownloadUri,
    required this.fallbackUploadUri,
  });

  factory SpeedTestConfig.fromJson(Map<String, dynamic> json) {
    final urls = json['urls'] as Map<String, dynamic>? ?? const {};
    final endpoint = sanitizeEndpointHost(
      json['test_endpoint'] as String? ?? 'mensura.cdn-apple.com',
    );

    final small = Uri.parse(
      urls['small_https_download_url'] as String? ??
          urls['small_download_url'] as String,
    );
    final large = Uri.parse(
      urls['large_https_download_url'] as String? ??
          urls['large_download_url'] as String,
    );
    final upload = Uri.parse(
      urls['https_upload_url'] as String? ?? urls['upload_url'] as String,
    );

    return SpeedTestConfig(
      testEndpoint: endpoint,
      smallDownloadUri: small.replace(host: endpoint),
      largeDownloadUri: large.replace(host: endpoint),
      uploadUri: upload.replace(host: endpoint),
      fallbackSmallDownloadUri: small,
      fallbackLargeDownloadUri: large,
      fallbackUploadUri: upload,
    );
  }

  SpeedTestConfig copyWithEndpoint(String endpoint) {
    final normalizedEndpoint = sanitizeEndpointHost(endpoint);
    return SpeedTestConfig(
      testEndpoint: normalizedEndpoint,
      smallDownloadUri: smallDownloadUri.replace(host: normalizedEndpoint),
      largeDownloadUri: largeDownloadUri.replace(host: normalizedEndpoint),
      uploadUri: uploadUri.replace(host: normalizedEndpoint),
      fallbackSmallDownloadUri: fallbackSmallDownloadUri,
      fallbackLargeDownloadUri: fallbackLargeDownloadUri,
      fallbackUploadUri: fallbackUploadUri,
    );
  }

  final String testEndpoint;
  final Uri smallDownloadUri;
  final Uri largeDownloadUri;
  final Uri uploadUri;
  final Uri fallbackSmallDownloadUri;
  final Uri fallbackLargeDownloadUri;
  final Uri fallbackUploadUri;
}

class SpeedTestOptions {
  const SpeedTestOptions({
    required this.mode,
    required this.endpointHost,
    required this.selectedIp,
  });

  final SpeedTestMode mode;
  final String endpointHost;
  final String? selectedIp;
}

class ResolvedAddressOption {
  const ResolvedAddressOption({
    required this.id,
    required this.label,
    required this.address,
    required this.family,
  });

  final String id;
  final String label;
  final String? address;
  final String family;
}

class DohResolution {
  const DohResolution({
    required this.host,
    required this.ipv4,
    required this.ipv6,
    required this.resolver,
    required this.resolvedAt,
  });

  static const empty = DohResolution(
    host: '',
    ipv4: <String>[],
    ipv6: <String>[],
    resolver: 'dns.google',
    resolvedAt: null,
  );

  final String host;
  final List<String> ipv4;
  final List<String> ipv6;
  final String resolver;
  final DateTime? resolvedAt;

  List<String> get allAddresses => <String>[...ipv4, ...ipv6];

  List<ResolvedAddressOption> get selectableAddresses =>
      <ResolvedAddressOption>[
        const ResolvedAddressOption(
          id: 'auto',
          label: '自动选择',
          address: null,
          family: 'AUTO',
        ),
        ...ipv4.map(
          (ip) => ResolvedAddressOption(
            id: 'ipv4-$ip',
            label: ip,
            address: ip,
            family: 'IPv4',
          ),
        ),
        ...ipv6.map(
          (ip) => ResolvedAddressOption(
            id: 'ipv6-$ip',
            label: ip,
            address: ip,
            family: 'IPv6',
          ),
        ),
      ];
}

class SpeedTestEndpointOption {
  const SpeedTestEndpointOption({
    required this.id,
    required this.label,
    required this.host,
    required this.description,
    required this.resolution,
    required this.isCustom,
  });

  final String id;
  final String label;
  final String host;
  final String description;
  final DohResolution resolution;
  final bool isCustom;
}

class SpeedTestBootstrap {
  const SpeedTestBootstrap({
    required this.config,
    required this.endpoints,
    required this.provider,
  });

  final SpeedTestConfig config;
  final List<SpeedTestEndpointOption> endpoints;
  final DohProvider provider;
}

class SpeedTestProgress {
  const SpeedTestProgress({
    required this.phase,
    required this.statusMessage,
    this.endpoint,
    this.usedIp,
    this.currentMbps,
    this.downloadMbps,
    this.uploadMbps,
    this.downloadedBytes,
    this.uploadedBytes,
    this.mode,
    this.phaseProgress,
    this.overallProgress,
  });

  final SpeedTestPhase phase;
  final String statusMessage;
  final String? endpoint;
  final String? usedIp;
  final double? currentMbps;
  final double? downloadMbps;
  final double? uploadMbps;
  final int? downloadedBytes;
  final int? uploadedBytes;
  final SpeedTestMode? mode;
  final double? phaseProgress;
  final double? overallProgress;
}

class SpeedTestResult {
  const SpeedTestResult({
    required this.endpoint,
    required this.mode,
    required this.downloadMbps,
    required this.uploadMbps,
    required this.downloadedBytes,
    required this.uploadedBytes,
    required this.finishedAt,
    required this.usedIp,
  });

  final String endpoint;
  final SpeedTestMode mode;
  final double downloadMbps;
  final double uploadMbps;
  final int downloadedBytes;
  final int uploadedBytes;
  final DateTime finishedAt;
  final String? usedIp;
}

class TargetIpInfo {
  const TargetIpInfo({
    required this.query,
    required this.asn,
    required this.asName,
    required this.country,
    required this.regionName,
    required this.city,
    required this.isp,
    required this.org,
  });

  factory TargetIpInfo.fromJson(Map<String, dynamic> json) {
    return TargetIpInfo(
      query: json['query'] as String? ?? '',
      asn: json['as'] as String? ?? '',
      asName: json['asname'] as String? ?? '',
      country: json['country'] as String? ?? '',
      regionName: json['regionName'] as String? ?? '',
      city: json['city'] as String? ?? '',
      isp: json['isp'] as String? ?? '',
      org: json['org'] as String? ?? '',
    );
  }

  final String query;
  final String asn;
  final String asName;
  final String country;
  final String regionName;
  final String city;
  final String isp;
  final String org;

  String get locationLabel {
    final parts = <String>[
      country,
      regionName,
      city,
    ].where((part) => part.trim().isNotEmpty).toList();
    return parts.isEmpty ? '未知位置' : parts.join(' / ');
  }
}

class SpeedTestCancelled implements Exception {
  const SpeedTestCancelled();

  @override
  String toString() => 'Speed test cancelled';
}
