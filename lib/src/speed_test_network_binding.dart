import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

class SpeedTestNetworkBinding {
  SpeedTestNetworkBinding({
    MethodChannel channel = const MethodChannel(_channelName),
    bool? enabled,
  }) : _channel = channel,
       _enabled = enabled ?? Platform.isAndroid;

  static const String _channelName = 'ispeedtest/network_binding';

  final MethodChannel _channel;
  final bool _enabled;

  Future<SpeedTestNetworkBindingLease> bindToNonVpnNetwork() async {
    if (!_enabled) {
      return SpeedTestNetworkBindingLease._noop();
    }

    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        'bindToNonVpnNetwork',
      );
      final didBind = response?['bound'] == true;
      final diagnostic = response?['diagnostic'] as String?;
      if (!didBind) {
        throw SpeedTestNetworkBindingException(diagnostic ?? '未找到可用的非 VPN 网络');
      }
      return SpeedTestNetworkBindingLease._(
        this,
        didBind: didBind,
        diagnostic: diagnostic,
      );
    } on MissingPluginException {
      throw const SpeedTestNetworkBindingException('平台通道不可用，无法确认绕过 VPN 是否生效');
    } on PlatformException catch (error) {
      throw SpeedTestNetworkBindingException(error.message ?? error.code);
    }
  }

  Future<void> _restore() async {
    if (!_enabled) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('restoreNetworkBinding');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}

class SpeedTestNetworkBindingLease {
  SpeedTestNetworkBindingLease._(
    this._binding, {
    required this.didBind,
    this.diagnostic,
  });

  SpeedTestNetworkBindingLease._noop()
    : _binding = null,
      didBind = false,
      diagnostic = null;

  factory SpeedTestNetworkBindingLease.noop() {
    return SpeedTestNetworkBindingLease._noop();
  }

  final SpeedTestNetworkBinding? _binding;
  final bool didBind;
  final String? diagnostic;
  bool _restored = false;

  Future<void> restore() async {
    if (_restored) {
      return;
    }
    _restored = true;
    await _binding?._restore();
  }
}

@visibleForTesting
class NoopSpeedTestNetworkBinding extends SpeedTestNetworkBinding {
  NoopSpeedTestNetworkBinding() : super(enabled: false);
}

class SpeedTestNetworkBindingException implements Exception {
  const SpeedTestNetworkBindingException(this.message);

  final String message;

  @override
  String toString() => '无法绕过 VPN: $message';
}
