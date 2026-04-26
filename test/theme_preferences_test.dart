import 'package:ispeedtest/src/theme_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ispeedtest/theme_preferences');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('loads a persisted theme color id', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getThemeColorId');
      return 'blue';
    });

    expect(await const ThemePreferences().loadThemeColorId(), 'blue');
  });

  test('saves the selected theme color id', () async {
    MethodCall? savedCall;
    messenger.setMockMethodCallHandler(channel, (call) async {
      savedCall = call;
      return null;
    });

    await const ThemePreferences().saveThemeColorId('green');

    expect(savedCall?.method, 'setThemeColorId');
    expect(savedCall?.arguments, 'green');
  });

  test('loads bypass vpn setting', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getBypassVpn');
      return true;
    });

    expect(await const ThemePreferences().loadBypassVpn(), isTrue);
  });

  test('saves bypass vpn setting', () async {
    MethodCall? savedCall;
    messenger.setMockMethodCallHandler(channel, (call) async {
      savedCall = call;
      return null;
    });

    await const ThemePreferences().saveBypassVpn(true);

    expect(savedCall?.method, 'setBypassVpn');
    expect(savedCall?.arguments, isTrue);
  });

  test('ignores missing platform storage', () async {
    expect(await const ThemePreferences().loadThemeColorId(), isNull);
    expect(await const ThemePreferences().loadBypassVpn(), isFalse);

    await const ThemePreferences().saveThemeColorId('purple');
    await const ThemePreferences().saveBypassVpn(true);
  });
}
