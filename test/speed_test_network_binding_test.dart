import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ispeedtest/src/speed_test_network_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpeedTestNetworkBinding', () {
    test('binds and restores through platform channel', () async {
      const channel = MethodChannel('test_network_binding');
      final calls = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'bindToNonVpnNetwork' => <String, Object?>{
                'bound': true,
                'diagnostic': '已绑定到 wifi internet+validated',
              },
              'restoreNetworkBinding' => null,
              _ => throw PlatformException(code: 'missing_method'),
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final binding = SpeedTestNetworkBinding(channel: channel, enabled: true);

      final lease = await binding.bindToNonVpnNetwork();
      await lease.restore();
      await lease.restore();

      expect(lease.didBind, isTrue);
      expect(lease.diagnostic, contains('wifi'));
      expect(calls, <String>['bindToNonVpnNetwork', 'restoreNetworkBinding']);
    });

    test('throws when platform cannot bind to non vpn network', () async {
      const channel = MethodChannel('failed_network_binding');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return <String, Object?>{
              'bound': false,
              'diagnostic': '没有发现非 VPN 的 INTERNET 网络',
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final binding = SpeedTestNetworkBinding(channel: channel, enabled: true);

      await expectLater(
        binding.bindToNonVpnNetwork(),
        throwsA(isA<SpeedTestNetworkBindingException>()),
      );
    });

    test('throws on missing platform implementation', () async {
      const channel = MethodChannel('missing_network_binding');
      final binding = SpeedTestNetworkBinding(channel: channel, enabled: true);

      await expectLater(
        binding.bindToNonVpnNetwork(),
        throwsA(isA<SpeedTestNetworkBindingException>()),
      );
    });
  });
}
