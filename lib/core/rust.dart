import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _CharPtr = Pointer<Utf8>;
typedef _JsonNative = _CharPtr Function(_CharPtr);
typedef _JsonDart = _CharPtr Function(_CharPtr);
typedef _VoidJsonNative = _CharPtr Function();
typedef _VoidJsonDart = _CharPtr Function();
typedef _U64JsonNative = _CharPtr Function(Uint64);
typedef _U64JsonDart = _CharPtr Function(int);
typedef _UsizeJsonNative = _CharPtr Function(IntPtr);
typedef _UsizeJsonDart = _CharPtr Function(int);
typedef _TunStartNative = _CharPtr Function(Int32, Uint32);
typedef _TunStartDart = _CharPtr Function(int, int);
typedef _FreeNative = Void Function(_CharPtr);
typedef _FreeDart = void Function(_CharPtr);

/// Direct bindings to the Rust networking core.
///
/// Every JSON call returns a freshly allocated C string which is copied into
/// Dart memory and released through `rp_free`, so no native memory leaks.
class RustCore {
  RustCore._() {
    _open();
  }

  RustCore._isolated() {
    _open();
  }

  static final RustCore instance = RustCore._();

  /// A fresh binding used inside background isolates. Only the dynamically
  /// loaded library handle lives here, so a new isolate can call into the same
  /// process-wide Rust runtime without sending native pointers around.
  static RustCore createIsolated() => RustCore._isolated();

  /// Runs a long native call off the UI thread. The request must be a plain
  /// JSON-like map; the worker opens its own library handle.
  static Future<Map<String, dynamic>> isolated(Map<String, dynamic> request) {
    return Isolate.run<Map<String, dynamic>>(() {
      final core = RustCore.createIsolated();
      return core._dispatch(request);
    });
  }

  Map<String, dynamic> _dispatch(Map<String, dynamic> request) {
    final op = (request['op'] ?? '').toString();
    switch (op) {
      case 'refresh_ips':
        return refreshIps();
      case 'test_proxy':
        return testProxy(
          (request['payload'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
              .map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        );
      case 'fetch_subscription':
        return fetchSubscription((request['url'] ?? '').toString());
      case 'speedtest':
        return speedtest();
      case 'leak_test':
        return leakTest();
      case 'dns_test':
        return dnsTest(
          (request['dns'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
              .map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          (request['host'] ?? 'example.com').toString(),
        );
      case 'engine_start':
        return engineStart(
          (request['config'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
              .map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        );
      case 'init':
        return init((request['dir'] ?? '').toString());
      default:
        return <String, dynamic>{'error': 'unknown background op: $op'};
    }
  }

  DynamicLibrary? _lib;

  bool get available => _lib != null;

  void _open() {
    if (_lib != null) return;
    final candidates = <String>[
      if (Platform.isAndroid) 'librustedproxy_core.so',
      if (Platform.isLinux) 'librustedproxy_core.so',
      if (Platform.isMacOS) 'librustedproxy_core.dylib',
      if (Platform.isWindows) 'rustedproxy_core.dll',
      if (Platform.isWindows) 'rust_core/target/release/rustedproxy_core.dll',
      if (Platform.isWindows) 'rust_core/target/debug/rustedproxy_core.dll',
    ];
    for (final name in candidates) {
      try {
        _lib = DynamicLibrary.open(name);
        return;
      } catch (_) {
        continue;
      }
    }
  }

  String? _take(_CharPtr ptr) {
    if (ptr == nullptr) return null;
    try {
      return ptr.toDartString();
    } finally {
      final lib = _lib;
      if (lib != null) {
        final free = lib.lookupFunction<_FreeNative, _FreeDart>('rp_free');
        free(ptr);
      }
    }
  }

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return <String, dynamic>{'error': 'native core unavailable'};
    }
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic>) return value;
      return <String, dynamic>{'value': value};
    } catch (_) {
      return <String, dynamic>{'error': raw};
    }
  }

  Map<String, dynamic> _call0(String name) {
    final lib = _lib;
    if (lib == null) return _decode(null);
    final fn = lib.lookupFunction<_VoidJsonNative, _VoidJsonDart>(name);
    return _decode(_take(fn()));
  }

  Map<String, dynamic> _call1(String name, String payload) {
    final lib = _lib;
    if (lib == null) return _decode(null);
    final fn = lib.lookupFunction<_JsonNative, _JsonDart>(name);
    final arg = payload.toNativeUtf8();
    try {
      return _decode(_take(fn(arg)));
    } finally {
      calloc.free(arg);
    }
  }

  Map<String, dynamic> _callU64(String name, int value) {
    final lib = _lib;
    if (lib == null) return _decode(null);
    final fn = lib.lookupFunction<_U64JsonNative, _U64JsonDart>(name);
    return _decode(_take(fn(value)));
  }

  Map<String, dynamic> _callUsize(String name, int value) {
    final lib = _lib;
    if (lib == null) return _decode(null);
    final fn = lib.lookupFunction<_UsizeJsonNative, _UsizeJsonDart>(name);
    return _decode(_take(fn(value)));
  }

  Map<String, dynamic> init(String dataDir) => _call1('rp_init', dataDir);

  Map<String, dynamic> engineStart(Map<String, dynamic> config) =>
      _call1('rp_engine_start', jsonEncode(config));

  Map<String, dynamic> engineStop() => _call0('rp_engine_stop');

  Map<String, dynamic> status() => _call0('rp_engine_status');

  Map<String, dynamic> logs(int after) => _callU64('rp_engine_logs', after);

  Map<String, dynamic> refreshIps() => _call0('rp_refresh_ips');

  Map<String, dynamic> swapRoute(int index) => _callUsize('rp_swap_route', index);

  Map<String, dynamic> testProxy(Map<String, dynamic> payload) =>
      _call1('rp_test_proxy', jsonEncode(payload));

  Map<String, dynamic> scanStart(Map<String, dynamic> config) =>
      _call1('rp_scan_start', jsonEncode(config));

  Map<String, dynamic> scanPoll() => _call0('rp_scan_poll');

  Map<String, dynamic> scanStop() => _call0('rp_scan_stop');

  Map<String, dynamic> parseText(String text, {String proto = 'socks5'}) =>
      _call1('rp_parse_text', jsonEncode({'text': text, 'proto': proto}));

  Map<String, dynamic> fetchSubscription(String url) =>
      _call1('rp_fetch_subscription', url);

  Map<String, dynamic> buildLink(Map<String, dynamic> proxy) =>
      _call1('rp_build_link', jsonEncode(proxy));

  Map<String, dynamic> geo(String ip) => _call1('rp_geo', ip);

  Map<String, dynamic> geoCity(String ip) => _call1('rp_geo_city', ip);

  Map<String, dynamic> tunStart(int fd, int mtu) {
    final lib = _lib;
    if (lib == null) return _decode(null);
    final fn = lib.lookupFunction<_TunStartNative, _TunStartDart>('rp_tun_start');
    return _decode(_take(fn(fd, mtu)));
  }

  Map<String, dynamic> tunStop() => _call0('rp_tun_stop');

  Map<String, dynamic> tunRunning() => _call0('rp_tun_running');

  Map<String, dynamic> speedtest() => _call1('rp_speedtest', '{}');

  Map<String, dynamic> leakTest() => _call0('rp_leak_test');

  Map<String, dynamic> dnsTest(Map<String, dynamic> dns, String host) =>
      _call1('rp_dns_test', jsonEncode(<String, dynamic>{'dns': dns, 'host': host}));

  Map<String, dynamic> buildInfo() => _call0('rp_build_info');
}
