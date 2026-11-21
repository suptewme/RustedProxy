import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/log_item.dart';
import '../models/proxy.dart';
import '../models/scan_snapshot.dart';
import '../models/settings.dart';
import 'platform.dart';
import 'rust.dart';

class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  final RustCore rust = RustCore.instance;

  AppSettings settings = AppSettings();
  List<ProxyServer> saved = <ProxyServer>[];
  ProxyServer? active;
  ProxyServer? entry;
  ProxyServer? exit;

  bool initialized = false;
  bool engineRunning = false;
  bool vpnRunning = false;
  bool busyConnecting = false;

  int listenPort = 0;
  int uptime = 0;
  int conns = 0;
  int totalConns = 0;
  int bytesUp = 0;
  int bytesDown = 0;
  double upRate = 0;
  double downRate = 0;

  String realIp = '';
  String exitIp = '';
  String exitCountry = '';
  String exitCity = '';
  String exitFlag = '🌐';

  List<LogItem> logs = <LogItem>[];
  int _logSeq = 0;
  bool logPaused = false;

  ScanSnapshot scan = ScanSnapshot();
  bool scanning = false;
  String scanMode = 'public';
  String scanProtocol = 'all';
  bool scanEncrypted = false;
  bool scanVideo = false;
  bool scanUdp = false;

  /// Ping range filter and ordering for the scan results list.
  int scanPingMin = 0;
  int scanPingMax = 0;
  bool scanSortDesc = false;
  String scanCountry = '';
  bool scanRanOnce = false;
  bool scanEmpty = false;

  bool speedTesting = false;
  bool leakTesting = false;
  bool pinging = false;
  bool refreshing = false;

  Map<String, dynamic> speedResult = <String, dynamic>{};
  List<Map<String, dynamic>> leakChecks = <Map<String, dynamic>>[];
  String? leakVisibleIp;
  String? leakRealIp;

  String? lastError;
  String networkType = 'none';

  bool rootAvailable = false;
  bool rootGranted = false;
  String rootManager = '';
  String rootSelinux = '';
  Map<String, dynamic> permissions = <String, dynamic>{};
  String navMode = 'unknown';

  /// Dedicated notifiers for values that must not rebuild the whole app on
  /// every one-second statistics tick.
  final ValueNotifier<String> themeModeNotifier = ValueNotifier<String>('dark');
  final ValueNotifier<String> navModeNotifier = ValueNotifier<String>('unknown');
  final ValueNotifier<bool> onboardingNotifier = ValueNotifier<bool>(false);

  /// Live-traffic snapshots, consumed only by the widgets that draw bytes,
  /// rates and the graph, so the one-second tick never rebuilds whole screens.
  final ValueNotifier<LiveStats> liveNotifier = ValueNotifier<LiveStats>(const LiveStats());

  bool _logsVisible = false;

  /// The logs tab announces itself so the ticker only pays for JSON log
  /// decoding while somebody is actually looking at them.
  void setLogsVisible(bool visible) => _logsVisible = visible;

  SharedPreferences? _prefs;
  Timer? _timer;
  Timer? _restartTimer;
  int _lastUp = 0;
  int _lastDown = 0;
  int _tickCount = 0;
  DateTime _lastRateAt = DateTime.now();
  bool _onboardingChecked = false;

  bool get hasActiveServer => active != null;

  /// Public nudge for lightweight view-only state (filters, toggles in sheets).
  void touch() => notifyListeners();

  List<ProxyServer> get chain {
    if (settings.multiHop && entry != null && exit != null) {
      if (entry!.key == exit!.key) {
        return <ProxyServer>[exit!];
      }
      return <ProxyServer>[entry!, exit!];
    }
    final target = active ?? exit ?? entry;
    return target == null ? <ProxyServer>[] : <ProxyServer>[target];
  }

  bool get isOn => engineRunning;

  String get modeLabel => settings.modeLabel;

  Future<void> init() async {
    if (initialized) return;
    _prefs = await SharedPreferences.getInstance();
    settings = AppSettings.decode(_prefs!.getString('rustproxy.settings'));
    themeModeNotifier.value = settings.themeMode;
    onboardingNotifier.value = settings.onboardingDone;
    saved = _decodeSaved(_prefs!.getString('rustproxy.saved'));
    active = _findById(_prefs!.getString('rustproxy.active'));
    entry = _findById(_prefs!.getString('rustproxy.entry'));
    exit = _findById(_prefs!.getString('rustproxy.exit'));
    if (active == null && saved.isNotEmpty) active = saved.first;
    exit ??= active;
    if (entry == null && saved.length > 1) {
      entry = saved.firstWhere((ProxyServer p) => p.key != exit?.key, orElse: () => saved.first);
    }
    if (!_onboardingChecked) {
      _onboardingChecked = true;
    }
    await RustCore.isolated(<String, dynamic>{'op': 'init', 'dir': ''});
    await PlatformBridge.setAutostart(settings.autostart);
    if (Platform.isAndroid) {
      navMode = await PlatformBridge.navMode();
      navModeNotifier.value = navMode;
      await refreshPermissions();
      await detectRoot();
    }
    _pullStatus();
    _startTimer();
    initialized = true;
    notifyListeners();
  }

  String? _findId(ProxyServer? p) => p?.id;

  /// Re-points the active/entry/exit references to the freshest instances from
  /// [saved] after a live update (latency, geo, name). Without this the home
  /// screen kept showing stale pings because the list holds copies.
  void _resyncRefs() {
    ProxyServer? fresh(ProxyServer? p) {
      if (p == null) return null;
      for (final candidate in saved) {
        if (candidate.key == p.key) return candidate;
      }
      return p;
    }

    active = fresh(active);
    entry = fresh(entry);
    exit = fresh(exit);
    if (active == null && saved.isNotEmpty) active = saved.first;
    exit ??= active;
  }

  ProxyServer? _findById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final p in saved) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<ProxyServer> _decodeSaved(String? raw) {
    if (raw == null || raw.isEmpty) return <ProxyServer>[];
    try {
      final value = jsonDecode(raw);
      if (value is List) {
        return value
            .whereType<Map<String, dynamic>>()
            .map(ProxyServer.fromJson)
            .toList(growable: true);
      }
    } catch (_) {}
    return <ProxyServer>[];
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _tick());
  }

  void _tick() {
    if (!initialized && _prefs == null) return;
    _tickCount++;
    final before = _signature();
    _pullStatus();
    // Logs are only polled for the tab that renders them. Polling them on the
    // home screen copied a growing list and re-serialised JSON every second,
    // which showed up as a micro-freeze once per second while connected.
    if (!logPaused && _logsVisible) _pullLogs();
    if (scanning) _pullScan();
    if (_tickCount % 20 == 0) {
      unawaited(_checkNetworkProfile());
      if (engineRunning && _tickCount % 60 == 0) {
        unawaited(_refreshIpsSilently());
      }
    }
    // Notify only when something actually changed. This keeps idle screens
    // completely still (no per-second repaint/flicker) while the animation
    // controllers inside the widgets keep running independently.
    if (before != _signature()) notifyListeners();
  }

  String _signature() => <Object>[
        engineRunning,
        vpnRunning,
        listenPort,
        logs.length,
        scanning,
        scan.phase,
        scan.checked,
        scan.total,
        scan.found.length,
      ].join(':');

  /// Publishes the traffic figures to the widgets that render them and keeps
  /// the coarse [ChangeNotifier] quiet while nothing structural changed.
  void _publishLive() {
    final next = LiveStats(
      uptime: uptime,
      conns: conns,
      totalConns: totalConns,
      bytesUp: bytesUp,
      bytesDown: bytesDown,
      upRate: upRate,
      downRate: downRate,
      connected: engineRunning,
    );
    if (LiveStats.differs(liveNotifier.value, next)) {
      liveNotifier.value = next;
    }
  }

  void _pullStatus() {
    final status = rust.status();
    final wasRunning = engineRunning;
    engineRunning = status['running'] == true;
    vpnRunning = status['tun'] == true;
    listenPort = (status['port'] as num?)?.toInt() ?? listenPort;
    uptime = (status['uptime'] as num?)?.toInt() ?? 0;
    conns = (status['conns'] as num?)?.toInt() ?? 0;
    totalConns = (status['total'] as num?)?.toInt() ?? 0;
    final up = (status['up'] as num?)?.toInt() ?? 0;
    final down = (status['down'] as num?)?.toInt() ?? 0;
    final now = DateTime.now();
    final seconds = now.difference(_lastRateAt).inMilliseconds / 1000.0;
    if (seconds >= 0.8) {
      if (_lastUp > 0 || _lastDown > 0) {
        final upDelta = (up - _lastUp).clamp(0, 1 << 62).toDouble();
        final downDelta = (down - _lastDown).clamp(0, 1 << 62).toDouble();
        upRate = (upDelta * 8) / seconds / 1000000.0;
        downRate = (downDelta * 8) / seconds / 1000000.0;
      }
      _lastUp = up;
      _lastDown = down;
      _lastRateAt = now;
    }
    bytesUp = up;
    bytesDown = down;
    realIp = (status['real_ip'] ?? realIp).toString();
    exitIp = (status['exit_ip'] ?? exitIp).toString();
    exitCountry = (status['exit_country'] ?? '').toString();
    exitCity = (status['exit_city'] ?? '').toString();
    exitFlag = (status['exit_flag'] ?? '🌐').toString();
    if (wasRunning && !engineRunning) {
      vpnRunning = false;
      upRate = 0;
      downRate = 0;
    }
    _publishLive();
  }

  void _pullLogs() {
    final result = rust.logs(_logSeq);
    final head = (result['head'] as num?)?.toInt() ?? _logSeq;
    final items = result['items'];
    if (items is List && items.isNotEmpty) {
      for (final item in items) {
        if (item is Map<String, dynamic>) {
          logs.add(LogItem.fromJson(item));
        }
      }
      if (logs.length > 800) {
        logs.removeRange(0, logs.length - 800);
      }
    }
    _logSeq = head;
  }

  void _pullScan() {
    final snapshot = ScanSnapshot.fromJson(rust.scanPoll());
    if (scanning && !snapshot.running && snapshot.phase == 'idle' && snapshot.total == 0) {
      // The core never started the background task (bad config / missing
      // library) — do not wait forever on a job that will not report back.
      scanning = false;
    } else {
      scan = snapshot;
      if (!snapshot.running) {
        scanning = false;
        scanRanOnce = true;
        scanEmpty = snapshot.found.isEmpty;
      }
    }
  }

  Future<void> _checkNetworkProfile() async {
    if (!Platform.isAndroid) return;
    final type = await PlatformBridge.networkType();
    if (type == networkType) return;
    networkType = type;
    if (!settings.smartProfiles || !engineRunning) {
      notifyListeners();
      return;
    }
    // Wi-Fi → full feature set, mobile network → everything through the proxy.
    final desired = type == 'wifi' ? 'full' : 'proxy';
    if (settings.mode != desired) {
      settings.mode = desired;
      _persistSettings();
      addLog(
        LogItem(
          seq: -1,
          ts: DateTime.now(),
          level: 'INFO',
          msg: 'Умный профиль сети → ${desired == 'full' ? 'Полная работа (Wi-Fi)' : 'Только прокси (мобильная сеть)'}',
        ),
      );
      await _restartEngine();
    }
    notifyListeners();
  }

  void addLog(LogItem item) {
    logs.add(item);
    if (logs.length > 800) logs = logs.sublist(logs.length - 800);
  }

  Map<String, dynamic> buildEngineConfig() {
    final chainServers = chain;
    final pool = saved.isEmpty ? chainServers : saved;
    return <String, dynamic>{
      'listen_port': settings.listenPort,
      'proxies': pool.map((ProxyServer p) => p.toRust()).toList(),
      'chain': chainServers.map((ProxyServer p) => p.toRust()).toList(),
      'settings': settings.toEngineSettings(),
    };
  }

  Future<void> connect({ProxyServer? proxy, bool silent = false}) async {
    if (busyConnecting) return;
    final target = proxy ?? active ?? exit ?? (saved.isNotEmpty ? saved.first : null);
    if (target == null) {
      lastError = 'Сначала добавьте или найдите прокси-сервер';
      notifyListeners();
      if (!silent) throw StateError(lastError!);
      return;
    }
    busyConnecting = true;
    lastError = null;
    notifyListeners();
    try {
      active = target;
      if (settings.multiHop) {
        // A tap on a server always selects it as the exit hop, so the
        // multi-hop switch and the server picker work together.
        exit = target;
        if (entry == null || entry!.key == target.key) {
          entry = saved.firstWhere(
            (ProxyServer p) => p.key != target.key,
            orElse: () => target,
          );
        }
      } else {
        exit = target;
      }
      final config = buildEngineConfig();
      final result = await RustCore.isolated(<String, dynamic>{
        'op': 'engine_start',
        'config': config,
      });
      if (result['error'] != null) {
        throw StateError(result['error'].toString());
      }
      engineRunning = true;
      _persistActive();
      if (Platform.isAndroid && settings.androidMode == 'vpn' && !vpnRunning) {
        final prepared = await PlatformBridge.prepareVpn();
        if (!prepared) {
          throw StateError('Разрешите подключение VPN в системном диалоге');
        }
        final vpnConfig = <String, dynamic>{
          ...config,
          'vpn': settings.toVpnOptions(),
        };
        final started = await PlatformBridge.startVpn(jsonEncode(vpnConfig));
        if (!started) {
          throw StateError('VPN-сервис не запустился');
        }
        vpnRunning = true;
      }
      if (Platform.isAndroid && rootAvailable) {
        if (settings.rootTuning) {
          final tuned = await PlatformBridge.rootTuning(true);
          if (tuned['ok'] != true) {
            lastError = 'Root BBR: ${tuned['output'] ?? 'команда не выполнена'}';
          }
        }
        if (settings.rootDnsRedirect) {
          final dns = await PlatformBridge.rootDnsRedirect(true, settings.dnsIp);
          if (dns['ok'] != true) {
            lastError = 'Root DNS: ${dns['output'] ?? 'команда не выполнена'}';
          }
        }
        if (settings.rootKillSwitch) {
          final kill = await PlatformBridge.rootKillSwitch(true);
          if (kill['ok'] != true) {
            lastError = 'Root kill switch: ${kill['output'] ?? 'команда не выполнена'}';
          }
        }
      }
      _pullStatus();
      unawaited(_refreshIpsSilently());
      _persistSettings();
    } catch (e) {
      lastError = e.toString().replaceFirst('Bad state: ', '');
      engineRunning = false;
      vpnRunning = false;
      try {
        rust.engineStop();
      } catch (_) {}
      notifyListeners();
      if (!silent) rethrow;
    } finally {
      busyConnecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    if (Platform.isAndroid) {
      try {
        if (settings.rootKillSwitch && rootAvailable) {
          await PlatformBridge.rootKillSwitch(false);
        }
        await PlatformBridge.stopVpn();
      } catch (_) {
        // The VPN service may already be gone; the native stop below is the
        // authoritative teardown.
      }
    }
    try {
      rust.engineStop();
    } catch (_) {}
    engineRunning = false;
    vpnRunning = false;
    upRate = 0;
    downRate = 0;
    uploadRateReset();
    uptime = 0;
    conns = 0;
    notifyListeners();
  }

  void uploadRateReset() {
    _lastUp = 0;
    _lastDown = 0;
    bytesUp = 0;
    bytesDown = 0;
  }

  Future<void> toggleConnection() async {
    if (engineRunning) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> _restartEngine() async {
    if (!engineRunning) return;
    try {
      final result = await RustCore.isolated(<String, dynamic>{
        'op': 'engine_start',
        'config': buildEngineConfig(),
      });
      if (result['error'] != null) {
        lastError = result['error'].toString();
      }
    } catch (e) {
      lastError = e.toString();
    }
  }

  void scheduleRestart() {
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_restartEngine());
    });
  }

  Future<void> _refreshIpsSilently() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final status = await RustCore.isolated(<String, dynamic>{'op': 'refresh_ips'});
      if (status['error'] == null) {
        _applyStatus(status);
      }
    } catch (_) {
    } finally {
      refreshing = false;
    }
  }

  void _applyStatus(Map<String, dynamic> status) {
    engineRunning = status['running'] == true;
    vpnRunning = status['tun'] == true;
    realIp = (status['real_ip'] ?? realIp).toString();
    exitIp = (status['exit_ip'] ?? exitIp).toString();
    exitCountry = (status['exit_country'] ?? exitCountry).toString();
    exitCity = (status['exit_city'] ?? exitCity).toString();
    exitFlag = (status['exit_flag'] ?? exitFlag).toString();
    notifyListeners();
  }

  Future<void> refreshIps() async {
    refreshing = true;
    notifyListeners();
    try {
      final status = await RustCore.isolated(<String, dynamic>{'op': 'refresh_ips'});
      if (status['error'] != null) {
        lastError = status['error'].toString();
      } else {
        _applyStatus(status);
      }
    } catch (e) {
      lastError = e.toString();
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  Future<void> refreshPermissions() async {
    final result = await PlatformBridge.permissions();
    if (result.isEmpty) return;
    permissions = result;
    final root = result['root'];
    if (root is Map) {
      _applyRootStatus(root.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)));
    }
    notifyListeners();
  }

  Future<void> detectRoot() async {
    final result = await PlatformBridge.rootStatus();
    if (result.isEmpty) return;
    _applyRootStatus(result);
    notifyListeners();
  }

  void _applyRootStatus(Map<String, dynamic> status) {
    rootAvailable = status['available'] == true;
    rootGranted = status['granted'] == true;
    rootManager = (status['manager'] ?? '').toString();
    rootSelinux = (status['selinux'] ?? '').toString();
  }

  Future<Map<String, dynamic>> requestPermission(String type) async {
    final result = await PlatformBridge.requestPermission(type);
    if (result.isNotEmpty) {
      permissions = result;
    } else {
      await refreshPermissions();
    }
    notifyListeners();
    return permissions;
  }

  Future<void> requestBatteryOptimization() async {
    await PlatformBridge.requestBatteryOptimization();
  }

  String get rootLabel {
    if (!rootAvailable) return 'Не обнаружен';
    if (rootGranted) {
      return rootManager.isNotEmpty ? '$rootManager · доступ выдан' : 'su · доступ выдан';
    }
    return rootManager.isNotEmpty ? '$rootManager · требуется доступ' : 'su найден · доступ не выдан';
  }

  Future<bool> _applyRootAction(
    Future<Map<String, dynamic>> Function() action, {
    void Function()? onSuccess,
    void Function()? onFailure,
  }) async {
    final result = await action();
    final ok = result['ok'] == true;
    final output = (result['output'] ?? '').toString();
    if (ok) {
      lastError = null;
      onSuccess?.call();
    } else {
      lastError = output.isEmpty ? 'Root-команда не выполнена' : output;
      onFailure?.call();
    }
    await detectRoot();
    notifyListeners();
    return ok;
  }

  Future<bool> requestRootAccess() {
    return _applyRootAction(
      () => PlatformBridge.rootCheck(),
      onSuccess: () {
        addLog(LogItem(
          seq: -1,
          ts: DateTime.now(),
          level: 'INFO',
          msg: 'Root: доступ подтверждён ($rootManager)',
        ));
      },
    );
  }

  Future<bool> setRootTuning(bool enabled) {
    return _applyRootAction(
      () => PlatformBridge.rootTuning(enabled),
      onSuccess: () {
        settings.rootTuning = enabled;
        _persistSettings();
        addLog(LogItem(
          seq: -1,
          ts: DateTime.now(),
          level: 'INFO',
          msg: enabled ? 'Root: включён TCP BBR и увеличены сетевые буферы' : 'Root: сетевые параметры сброшены',
        ));
      },
    );
  }

  Future<bool> setRootKillSwitch(bool enabled) async {
    settings.rootKillSwitch = enabled;
    _persistSettings();
    notifyListeners();
    // While disconnected there is nothing to protect — the rule is applied on connect.
    if (!engineRunning) return true;
    return _applyRootAction(
      () => PlatformBridge.rootKillSwitch(enabled),
      onSuccess: () => addLog(LogItem(
        seq: -1,
        ts: DateTime.now(),
        level: 'INFO',
        msg: enabled
            ? 'Root: kill switch активен (разрешён только UID ядра)'
            : 'Root: kill switch отключён',
      )),
    );
  }

  Future<bool> setRootDnsRedirect(bool enabled) {
    return _applyRootAction(
      () => PlatformBridge.rootDnsRedirect(enabled, settings.dnsIp),
      onSuccess: () {
        settings.rootDnsRedirect = enabled;
        _persistSettings();
        addLog(LogItem(
          seq: -1,
          ts: DateTime.now(),
          level: 'INFO',
          msg: enabled
              ? 'Root: DNS-запросы принудительно идут на ${settings.dnsIp}'
              : 'Root: перехват DNS отключён',
        ));
      },
      onFailure: () {
        settings.rootDnsRedirect = !enabled;
        _persistSettings();
      },
    );
  }

  Future<bool> setRootAlwaysOn(bool enabled) {
    return _applyRootAction(
      () => PlatformBridge.rootAlwaysOn(enabled),
      onSuccess: () {
        settings.rootAlwaysOn = enabled;
        _persistSettings();
      },
      onFailure: () {
        settings.rootAlwaysOn = !enabled;
        _persistSettings();
      },
    );
  }

  Future<bool> clearDnsCache() {
    return _applyRootAction(() => PlatformBridge.rootClearDns());
  }

  void updateSettings(void Function(AppSettings s) mutate, {bool restart = false}) {
    final previousTheme = settings.themeMode;
    final wasOnboarded = settings.onboardingDone;
    mutate(settings);
    _persistSettings();
    if (settings.themeMode != previousTheme) {
      themeModeNotifier.value = settings.themeMode;
    }
    if (settings.onboardingDone != wasOnboarded) {
      onboardingNotifier.value = settings.onboardingDone;
    }
    if (settings.autostart) {
      unawaited(PlatformBridge.setAutostart(true));
    } else {
      unawaited(PlatformBridge.setAutostart(false));
    }
    notifyListeners();
    if (restart) scheduleRestart();
  }

  /// Re-reads the Android navigation style (gesture / 3-button) after resume.
  Future<void> refreshNavMode() async {
    if (!Platform.isAndroid) return;
    final mode = await PlatformBridge.navMode();
    if (mode == navMode) return;
    navMode = mode;
    navModeNotifier.value = mode;
  }

  /// Verifies the configured DNS transport with a real resolution.
  Future<Map<String, dynamic>> testDns(String host) async {
    try {
      final result = await RustCore.isolated(<String, dynamic>{
        'op': 'dns_test',
        'host': host.isEmpty ? 'example.com' : host,
        'dns': settings.toEngineSettings()['dns'],
      });
      if (result['ok'] != true) {
        lastError = (result['error'] ?? 'DNS недоступен').toString();
      }
      notifyListeners();
      return result;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return <String, dynamic>{'ok': false, 'error': e.toString()};
    }
  }

  void setMode(String mode) {
    if (settings.mode == mode) return;
    updateSettings((AppSettings s) => s.mode = mode, restart: engineRunning);
  }

  Future<void> saveProxy(ProxyServer proxy, {bool makeActive = false}) async {
    final index = saved.indexWhere((ProxyServer p) => p.key == proxy.key);
    if (index >= 0) {
      saved[index] = proxy;
    } else {
      saved.add(proxy);
    }
    if (makeActive || active == null) {
      active = proxy;
      exit = proxy;
    }
    if (entry == null && saved.length > 1) {
      entry = saved.firstWhere((ProxyServer p) => p.key != (exit ?? proxy).key,
          orElse: () => proxy);
    }
    _resyncRefs();
    _persistSaved();
    _persistActive();
    notifyListeners();
    if (makeActive && engineRunning) {
      await connect(proxy: proxy, silent: true);
    }
  }

  Future<void> saveMany(List<ProxyServer> proxies) async {
    for (final proxy in proxies) {
      final index = saved.indexWhere((ProxyServer p) => p.key == proxy.key);
      if (index >= 0) {
        saved[index] = proxy;
      } else {
        saved.add(proxy);
      }
    }
    active ??= saved.isNotEmpty ? saved.first : null;
    exit ??= active;
    if (entry == null && saved.length > 1) {
      entry = saved.firstWhere((ProxyServer p) => p.key != (exit ?? active)?.key,
          orElse: () => saved.first);
    }
    _resyncRefs();
    _persistSaved();
    _persistActive();
    notifyListeners();
  }

  Future<void> deleteProxy(ProxyServer proxy) async {
    saved.removeWhere((ProxyServer p) => p.key == proxy.key);
    if (active?.key == proxy.key) {
      active = saved.isNotEmpty ? saved.first : null;
      exit = active;
      if (engineRunning) await _restartEngine();
    }
    if (entry?.key == proxy.key) {
      entry = saved.isNotEmpty ? saved.first : null;
    }
    _persistSaved();
    _persistActive();
    notifyListeners();
  }

  Future<void> clearSaved() async {
    saved = <ProxyServer>[];
    active = null;
    entry = null;
    exit = null;
    _persistSaved();
    _persistActive();
    notifyListeners();
  }

  Future<int> importText(String text, {String proto = 'socks5'}) async {
    if (text.trim().isEmpty) return 0;
    final result = rust.parseText(text, proto: proto);
    final list = (result['proxies'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(ProxyServer.fromJson)
        .toList();
    if (list.isNotEmpty) {
      await saveMany(list);
    }
    return list.length;
  }

  Future<int> fetchSubscription(String url) async {
    final result = await RustCore.isolated(<String, dynamic>{
      'op': 'fetch_subscription',
      'url': url,
    });
    if (result['error'] != null) {
      throw StateError(result['error'].toString());
    }
    final list = (result['proxies'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(ProxyServer.fromJson)
        .toList();
    await saveMany(list);
    return list.length;
  }

  Future<String?> buildLink(ProxyServer proxy) async {
    final result = rust.buildLink(proxy.toRust());
    if (result['link'] != null) return result['link'].toString();
    return null;
  }

  Future<void> startScan() async {
    if (scanning) return;
    scan = ScanSnapshot(running: true, phase: 'fetching');
    scanning = true;
    lastError = null;
    final config = <String, dynamic>{
      'mode': scanMode,
      'sources': <Map<String, dynamic>>[],
      'workers': settings.workers,
      'timeout_ms': settings.timeoutMs,
      'check_url': settings.checkUrl,
      'speed_check': settings.speedCheck,
      'service_check': settings.serviceCheck,
      'anonymity_check': settings.anonymityCheck,
      'max_candidates': 1200,
      'protocol_filter': scanProtocol,
      'require_encrypted': scanEncrypted,
    };
    try {
      final result = rust.scanStart(config);
      if (result['error'] != null && result['running'] != true) {
        scanning = false;
        lastError = result['error'].toString();
      } else {
        scan = ScanSnapshot.fromJson(result);
      }
    } catch (e) {
      scanning = false;
      lastError = e.toString();
      scan = ScanSnapshot();
    }
    scanRanOnce = true;
    scanEmpty = false;
    notifyListeners();
  }

  void stopScan() {
    rust.scanStop();
    scanning = false;
    scan = ScanSnapshot.fromJson(rust.scanPoll());
    notifyListeners();
  }

  List<ProxyServer> get filteredScanResults {
    final min = scanPingMin;
    final max = scanPingMax;
    final country = scanCountry;
    var list = scan.found.where((ProxyServer p) {
      if (p.latency <= 0) return false;
      if (min > 0 && p.latency < min) return false;
      if (max > 0 && p.latency > max) return false;
      if (country.isNotEmpty && p.countryCode != country) return false;
      return true;
    }).toList();
    if (scanVideo) {
      list = list.where((ProxyServer p) => p.speed >= 15).toList();
    }
    if (scanUdp) {
      list = list
          .where((ProxyServer p) =>
              p.tags.any((String t) => t.toLowerCase() == 'udp') ||
              p.proto == 'socks5' ||
              p.proto == 'trojan' ||
              p.proto == 'vless' ||
              p.proto == 'ss')
          .toList();
    }
    list.sort((ProxyServer a, ProxyServer b) => scanSortDesc
        ? b.latency.compareTo(a.latency)
        : a.latency.compareTo(b.latency));
    return list;
  }

  /// Countries present in the current results, sorted by frequency.
  List<MapEntry<String, int>> get scanCountries {
    final counts = <String, int>{};
    for (final p in scan.found) {
      if (p.countryCode.isEmpty) continue;
      counts[p.countryCode] = (counts[p.countryCode] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) => b.value.compareTo(a.value));
    return entries;
  }

  Future<void> pingAll() async {
    if (pinging || saved.isEmpty) return;
    pinging = true;
    notifyListeners();
    final targets = List<ProxyServer>.from(saved);
    final updated = <String, ProxyServer>{};
    final chunks = <List<ProxyServer>>[];
    const chunkSize = 8;
    for (var i = 0; i < targets.length; i += chunkSize) {
      chunks.add(targets.sublist(i, (i + chunkSize).clamp(0, targets.length)));
    }
    for (final chunk in chunks) {
      await Future.wait(chunk.map((ProxyServer proxy) async {
        try {
          final payload = <String, dynamic>{
            'proxy': proxy.toRust(),
            'timeout_ms': settings.timeoutMs,
            'check_url': settings.checkUrl,
          };
          final result = await RustCore.isolated(<String, dynamic>{
            'op': 'test_proxy',
            'payload': payload,
          });
          if (result['ok'] == true) {
            final latency = (result['latency'] as num?)?.toInt() ?? 0;
            updated[proxy.key] = proxy.copyWith(
              latency: latency,
              country: (result['country'] ?? '').toString().isEmpty
                  ? proxy.country
                  : result['country'].toString(),
              countryCode: (result['country_code'] ?? '').toString().isEmpty
                  ? proxy.countryCode
                  : result['country_code'].toString(),
              city: (result['city'] ?? '').toString().isEmpty
                  ? proxy.city
                  : result['city'].toString(),
              flag: (result['flag'] ?? '').toString().isEmpty
                  ? proxy.flag
                  : result['flag'].toString(),
            );
          } else {
            updated[proxy.key] = proxy.copyWith(latency: 0);
          }
        } catch (_) {
          updated[proxy.key] = proxy.copyWith(latency: 0);
        }
      }));
      saved = saved
          .map((ProxyServer p) => updated[p.key] ?? p)
          .toList(growable: true);
      _resyncRefs();
      notifyListeners();
    }
    _persistSaved();
    pinging = false;
    notifyListeners();
  }

  Future<void> testSingle(ProxyServer proxy) async {
    final payload = <String, dynamic>{
      'proxy': proxy.toRust(),
      'timeout_ms': settings.timeoutMs.clamp(1500, 8000),
      'check_url': settings.checkUrl,
    };
    final result = await RustCore.isolated(<String, dynamic>{
      'op': 'test_proxy',
      'payload': payload,
    });
    if (result['ok'] == true) {
      final updated = proxy.copyWith(
        latency: (result['latency'] as num?)?.toInt() ?? 0,
        country: (result['country'] ?? '').toString(),
        countryCode: (result['country_code'] ?? '').toString(),
        city: (result['city'] ?? '').toString(),
        flag: (result['flag'] ?? '🌐').toString(),
      );
      final index = saved.indexWhere((ProxyServer p) => p.key == proxy.key);
      if (index >= 0) saved[index] = updated;
      _resyncRefs();
      notifyListeners();
      _persistSaved();
    }
  }

  Future<void> runSpeedtest() async {
    if (speedTesting) return;
    speedTesting = true;
    speedResult = <String, dynamic>{};
    notifyListeners();
    try {
      final result = await RustCore.isolated(<String, dynamic>{'op': 'speedtest'});
      if (result['error'] != null) {
        lastError = result['error'].toString();
        speedResult = <String, dynamic>{};
      } else {
        speedResult = result;
      }
    } catch (e) {
      lastError = e.toString();
      speedResult = <String, dynamic>{};
    } finally {
      speedTesting = false;
      notifyListeners();
    }
  }

  Future<void> runLeakTest() async {
    if (leakTesting) return;
    leakTesting = true;
    leakChecks = <Map<String, dynamic>>[];
    notifyListeners();
    try {
      final result = await RustCore.isolated(<String, dynamic>{'op': 'leak_test'});
      if (result['error'] != null) {
        lastError = result['error'].toString();
      } else {
        leakChecks = (result['checks'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList();
        leakVisibleIp = result['visible_ip']?.toString();
        leakRealIp = result['real_ip']?.toString();
      }
    } catch (e) {
      lastError = e.toString();
    } finally {
      leakTesting = false;
      notifyListeners();
    }
  }

  Future<void> switchToNext() async {
    if (saved.isEmpty) return;
    final currentKey = (active ?? saved.first).key;
    final pool = List<ProxyServer>.from(saved)
      ..sort((ProxyServer a, ProxyServer b) {
        final la = a.latency == 0 ? 99999 : a.latency;
        final lb = b.latency == 0 ? 99999 : b.latency;
        return la.compareTo(lb);
      });
    final idx = pool.indexWhere((ProxyServer p) => p.key == currentKey);
    final next = pool[(idx + 1) % pool.length];
    await connect(proxy: next, silent: true);
  }

  void setActive(ProxyServer proxy) {
    active = proxy;
    if (!settings.multiHop) exit = proxy;
    entry ??= saved.firstWhere(
      (ProxyServer p) => p.key != proxy.key,
      orElse: () => proxy,
    );
    _persistActive();
    notifyListeners();
    if (engineRunning) {
      unawaited(connect(proxy: proxy, silent: true));
    }
  }

  void setEntry(ProxyServer proxy) {
    entry = proxy;
    _persistActive();
    notifyListeners();
    if (engineRunning) scheduleRestart();
  }

  void setExit(ProxyServer proxy) {
    exit = proxy;
    active = proxy;
    _persistActive();
    notifyListeners();
    if (engineRunning) scheduleRestart();
  }

  void setMultiHop(bool enabled) {
    settings.multiHop = enabled;
    if (enabled) {
      exit ??= active;
      if (saved.isEmpty) {
        entry = null;
        exit = active;
      } else if (entry == null || entry!.key == exit?.key) {
        entry = saved.firstWhere(
          (ProxyServer p) => p.key != exit?.key,
          orElse: () => saved.first,
        );
      }
    }
    _persistSettings();
    _persistActive();
    notifyListeners();
    if (engineRunning) scheduleRestart();
  }

  void completeOnboarding({bool applyPreset = true}) {
    settings.onboardingDone = true;
    _persistSettings();
    onboardingNotifier.value = true;
    notifyListeners();
  }

  void resetAll() {
    final wasRoot = rootAvailable;
    final dnsServer = settings.dnsIp;
    unawaited(disconnect());
    if (Platform.isAndroid && wasRoot) {
      unawaited(PlatformBridge.rootDnsRedirect(false, dnsServer));
      unawaited(PlatformBridge.rootAlwaysOn(false));
    }
    settings = AppSettings()..onboardingDone = true;
    themeModeNotifier.value = settings.themeMode;
    onboardingNotifier.value = true;
    saved = <ProxyServer>[];
    active = null;
    entry = null;
    exit = null;
    logs = <LogItem>[];
    _logSeq = 0;
    _persistSettings();
    _persistSaved();
    _persistActive();
    notifyListeners();
  }

  void clearLogs() {
    logs = <LogItem>[];
    _logSeq = rust.logs(0)['head'] as int? ?? _logSeq;
    notifyListeners();
  }

  void _persistSettings() {
    _prefs?.setString('rustproxy.settings', settings.encode());
  }

  void _persistSaved() {
    _prefs?.setString(
      'rustproxy.saved',
      jsonEncode(saved.map((ProxyServer p) => p.toJson()).toList()),
    );
  }

  void _persistActive() {
    _prefs?.setString('rustproxy.active', _findId(active) ?? '');
    _prefs?.setString('rustproxy.entry', _findId(entry) ?? '');
    _prefs?.setString('rustproxy.exit', _findId(exit) ?? '');
  }

  @override
  void dispose() {
    _timer?.cancel();
    _restartTimer?.cancel();
    super.dispose();
  }
}

/// Immutable traffic snapshot published once per second. Widgets that draw
/// bytes, rates and the graph listen to this instead of the whole AppState, so
/// a tick repaints a handful of leaves instead of every screen.
class LiveStats {
  const LiveStats({
    this.uptime = 0,
    this.conns = 0,
    this.totalConns = 0,
    this.bytesUp = 0,
    this.bytesDown = 0,
    this.upRate = 0,
    this.downRate = 0,
    this.connected = false,
  });

  final int uptime;
  final int conns;
  final int totalConns;
  final int bytesUp;
  final int bytesDown;
  final double upRate;
  final double downRate;
  final bool connected;

  static bool differs(LiveStats a, LiveStats b) =>
      a.uptime != b.uptime ||
      a.conns != b.conns ||
      a.totalConns != b.totalConns ||
      a.bytesUp != b.bytesUp ||
      a.bytesDown != b.bytesDown ||
      (a.upRate - b.upRate).abs() > 0.001 ||
      (a.downRate - b.downRate).abs() > 0.001 ||
      a.connected != b.connected;
}
