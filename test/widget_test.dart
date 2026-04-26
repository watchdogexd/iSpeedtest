import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material3_showcase/main.dart';
import 'package:material3_showcase/src/speed_test_models.dart';
import 'package:material3_showcase/src/speed_test_service.dart';

void main() {
  testWidgets('renders Apple speed test dashboard', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(AppleSpeedApp(service: _FakeSpeedTestService()));
    await tester.pumpAndSettle();

    expect(find.text('Apple CDN Speed Test'), findsOneWidget);
    expect(find.text('当前速度'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('上传'), findsOneWidget);
    expect(find.textContaining('连接 IP:'), findsNothing);
    expect(find.byTooltip('刷新节点'), findsOneWidget);
    expect(find.byTooltip('添加节点'), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('测速模式'),
      find.byType(Scrollable),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();

    expect(find.text('测速模式'), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('DoH 提供商'),
      find.byType(Scrollable),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();

    expect(find.text('DoH 提供商'), findsOneWidget);
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Cloudflare'), findsOneWidget);
    expect(find.text('阿里云'), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('测速节点'),
      find.byType(Scrollable),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();

    expect(find.text('测速节点'), findsOneWidget);
    expect(find.text('选择测速节点'), findsOneWidget);
    expect(find.text('选择测速 IP'), findsOneWidget);
  });
}

class _FakeSpeedTestService extends SpeedTestService {
  @override
  Future<SpeedTestBootstrap> bootstrap({
    required DohProvider provider,
    List<String> customHosts = const [],
  }) async {
    return SpeedTestBootstrap(
      config: SpeedTestConfig(
        testEndpoint: 'mensura.cdn-apple.com',
        smallDownloadUri: Uri.parse('https://mensura.cdn-apple.com/small'),
        largeDownloadUri: Uri.parse('https://mensura.cdn-apple.com/large'),
        uploadUri: Uri.parse('https://mensura.cdn-apple.com/upload'),
        fallbackSmallDownloadUri: Uri.parse(
          'https://mensura.cdn-apple.com/small',
        ),
        fallbackLargeDownloadUri: Uri.parse(
          'https://mensura.cdn-apple.com/large',
        ),
        fallbackUploadUri: Uri.parse('https://mensura.cdn-apple.com/upload'),
      ),
      endpoints: const [
        SpeedTestEndpointOption(
          id: 'mensura.cdn-apple.com',
          label: '默认入口节点',
          host: 'mensura.cdn-apple.com',
          description: '使用 Apple 默认入口域名测速',
          isCustom: false,
          resolution: DohResolution(
            host: 'mensura.cdn-apple.com',
            ipv4: <String>['17.253.27.205'],
            ipv6: <String>['2403:300:a06:f000::1'],
            resolver: 'dns.alidns.com',
            resolvedAt: null,
          ),
        ),
      ],
      provider: provider,
    );
  }

  @override
  Future<TargetIpInfo?> fetchTargetIpInfo({required String? query}) async {
    return const TargetIpInfo(
      query: '17.253.27.205',
      asn: 'AS714',
      asName: 'APPLE-ENGINEERING',
      country: 'United States',
      regionName: 'California',
      city: 'Cupertino',
      isp: 'Apple',
      org: 'Apple',
    );
  }
}
