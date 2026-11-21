import 'package:flutter/services.dart';

/// Bridge to the Android host: VPN lifecycle, package list, sharing.
class PlatformBridge {
  static const MethodChannel _channel = MethodChannel('dev.rustedproxy/app');

  static Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> prepareVpn() async =>
      await _invoke<bool>('prepareVpn') ?? false;

  static Future<bool> startVpn(String config) async =>
      await _invoke<bool>('startVpn', <String, dynamic>{'config': config}) ?? false;

  static Future<bool> stopVpn() async => await _invoke<bool>('stopVpn') ?? false;

  static Future<Map<String, dynamic>> vpnState() async {
    final result = await _invoke<Map<dynamic, dynamic>>('vpnState');
    return result?.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)) ??
        <String, dynamic>{'running': false, 'error': '', 'prepared': false};
  }

  static Future<List<Map<String, dynamic>>> installedApps() async {
    final result = await _invoke<List<dynamic>>('installedApps');
    if (result == null) return const <Map<String, dynamic>>[];
    return result
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> e) =>
            e.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)))
        .toList(growable: false);
  }

  static Future<void> setAutostart(bool enabled) async {
    await _invoke<bool>('saveAutostart', <String, dynamic>{'enabled': enabled});
  }

  static Future<bool> autostart() async => await _invoke<bool>('autostart') ?? false;

  static Future<void> openVpnSettings() async {
    await _invoke<bool>('openVpnSettings');
  }

  static Future<void> openAppSettings() async {
    await _invoke<bool>('openAppSettings');
  }

  static Future<void> shareText(String text) async {
    await _invoke<bool>('shareText', <String, dynamic>{'text': text});
  }

  static Future<Map<String, dynamic>> appInfo() async {
    final result = await _invoke<Map<dynamic, dynamic>>('appInfo');
    return result?.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)) ??
        <String, dynamic>{};
  }

  static Future<String> networkType() async =>
      await _invoke<String>('networkType') ?? 'none';

  /// Android navigation style: gesture / threeButton / twoButton / unknown.
  static Future<String> navMode() async =>
      await _invoke<String>('navMode') ?? 'unknown';

  static Map<String, dynamic> _map(Object? value) {
    final result = value as Map<dynamic, dynamic>?;
    return result?.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)) ??
        <String, dynamic>{};
  }

  static Future<Map<String, dynamic>> permissions() async =>
      _map(await _invoke<Map<dynamic, dynamic>>('permissions'));

  static Future<Map<String, dynamic>> requestPermission(String type) async =>
      _map(await _invoke<Map<dynamic, dynamic>>(
        'requestPermission',
        <String, dynamic>{'type': type},
      ));

  static Future<bool> requestBatteryOptimization() async =>
      await _invoke<bool>('requestBatteryOptimization') ?? false;

  static Future<void> openNotificationSettings() async {
    await _invoke<bool>('openNotificationSettings');
  }

  static Future<void> openBatterySettings() async {
    await _invoke<bool>('openBatterySettings');
  }

  static Future<Map<String, dynamic>> rootStatus() async =>
      _map(await _invoke<Map<dynamic, dynamic>>('rootStatus'));

  static Future<Map<String, dynamic>> rootCheck() async =>
      _map(await _invoke<Map<dynamic, dynamic>>('rootCheck'));

  static Future<Map<String, dynamic>> rootTuning(bool enabled) async =>
      _map(await _invoke<Map<dynamic, dynamic>>(
        'rootTuning',
        <String, dynamic>{'enabled': enabled},
      ));

  static Future<Map<String, dynamic>> rootKillSwitch(bool enabled) async =>
      _map(await _invoke<Map<dynamic, dynamic>>(
        'rootKillSwitch',
        <String, dynamic>{'enabled': enabled},
      ));

  static Future<Map<String, dynamic>> rootDnsRedirect(
    bool enabled,
    String server,
  ) async =>
      _map(await _invoke<Map<dynamic, dynamic>>(
        'rootDnsRedirect',
        <String, dynamic>{'enabled': enabled, 'server': server},
      ));

  static Future<Map<String, dynamic>> rootClearDns() async =>
      _map(await _invoke<Map<dynamic, dynamic>>('rootClearDns'));

  static Future<Map<String, dynamic>> rootAlwaysOn(bool enabled) async =>
      _map(await _invoke<Map<dynamic, dynamic>>(
        'rootAlwaysOn',
        <String, dynamic>{'enabled': enabled},
      ));

  /// Receives proxy links sent while the app is running.
  static void onDeepLink(Future<void> Function(String link) handler) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'deepLink') {
        final link = call.arguments?.toString() ?? '';
        if (link.isNotEmpty) await handler(link);
        return true;
      }
      return null;
    });
  }

  static Future<String?> takeInitialLink() async =>
      _invoke<String>('takeInitialLink');
}
