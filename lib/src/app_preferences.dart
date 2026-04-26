import 'package:flutter/services.dart';

class AppPreferences {
  const AppPreferences({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const _channelName = 'ispeedtest/theme_preferences';
  static const _getThemeColorIdMethod = 'getThemeColorId';
  static const _setThemeColorIdMethod = 'setThemeColorId';
  static const _getBypassVpnMethod = 'getBypassVpn';
  static const _setBypassVpnMethod = 'setBypassVpn';

  final MethodChannel _channel;

  Future<String?> loadThemeColorId() async {
    try {
      final value = await _channel.invokeMethod<String>(_getThemeColorIdMethod);
      final themeColorId = value?.trim();
      return themeColorId == null || themeColorId.isEmpty ? null : themeColorId;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> saveThemeColorId(String themeColorId) async {
    final normalizedThemeColorId = themeColorId.trim();
    if (normalizedThemeColorId.isEmpty) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        _setThemeColorIdMethod,
        normalizedThemeColorId,
      );
    } on MissingPluginException {
      return;
    }
  }

  Future<bool> loadBypassVpn() async {
    try {
      return await _channel.invokeMethod<bool>(_getBypassVpnMethod) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> saveBypassVpn(bool value) async {
    try {
      await _channel.invokeMethod<void>(_setBypassVpnMethod, value);
    } on MissingPluginException {
      return;
    }
  }
}
