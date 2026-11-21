import 'dart:convert';

/// All user-visible preferences. The same object feeds the Rust engine,
/// the VPN builder and the persistent store.
class AppSettings {
  AppSettings();

  String mode = 'full'; // full | proxy
  bool bypassRu = true;
  bool bypassAll = false;
  List<String> bypassDomains = <String>[];
  bool lanBypass = true;
  bool adblock = true;
  bool blockQuic = true;
  bool disableIpv6 = true;
  bool dpiBypass = true;
  String dpiMethod = 'split'; // split | sni | byte
  int fragSize = 40;
  bool killSwitch = true;
  bool blockUnencrypted = true;
  bool autoFailover = true;
  int rotationSecs = 0;
  String dnsProtocol = 'doh'; // doh | dot | udp
  String dnsServer = 'cloudflare'; // cloudflare | google | adguard | quad9 | custom
  String customDns = '';
  bool dnsLeak = true;
  int mtu = 1400;
  bool udpTcp = false;
  String androidMode = 'vpn'; // vpn | local
  int workers = 200;
  int timeoutMs = 2000;
  String checkUrl = 'https://cp.cloudflare.com/generate_204';
  bool speedCheck = true;
  bool serviceCheck = false;
  bool anonymityCheck = true;
  bool multiHop = false;
  bool autostart = false;
  bool smartProfiles = true;
  String splitMode = 'off'; // off | whitelist | blacklist
  List<String> selectedApps = <String>[];
  String themeMode = 'dark'; // dark | light ('system' is read for compatibility only)
  bool onboardingDone = false;
  int listenPort = 10808;
  bool rootTuning = false;
  bool rootKillSwitch = false;
  bool rootDnsRedirect = false;
  bool rootAlwaysOn = false;

  static const Map<String, String> dohServers = <String, String>{
    'cloudflare': 'https://cloudflare-dns.com/dns-query',
    'google': 'https://dns.google/dns-query',
    'adguard': 'https://dns.adguard-dns.com/dns-query',
    'quad9': 'https://dns.quad9.net/dns-query',
  };

  static const Map<String, String> ipServers = <String, String>{
    'cloudflare': '1.1.1.1',
    'google': '8.8.8.8',
    'adguard': '94.140.14.14',
    'quad9': '9.9.9.9',
  };

  String get dnsServerValue {
    if (dnsServer == 'custom' && customDns.trim().isNotEmpty) {
      final raw = customDns.trim();
      if (dnsProtocol == 'doh' && !raw.startsWith('http')) {
        return 'https://$raw/dns-query';
      }
      return raw;
    }
    if (dnsProtocol == 'doh') {
      return dohServers[dnsServer] ?? dohServers['cloudflare']!;
    }
    return ipServers[dnsServer] ?? ipServers['cloudflare']!;
  }

  String get dnsIp {
    final value = dnsServerValue;
    if (value.startsWith('http')) {
      final uri = Uri.tryParse(value);
      final host = uri?.host ?? '';
      if (host.contains('cloudflare')) return '1.1.1.1';
      if (host.contains('google')) return '8.8.8.8';
      if (host.contains('adguard')) return '94.140.14.14';
      if (host.contains('quad9')) return '9.9.9.9';
      return '1.1.1.1';
    }
    return value.split('/').first.split(':').first;
  }

  String get dnsLabel {
    switch (dnsProtocol) {
      case 'doh':
        return 'DoH';
      case 'dot':
        return 'DoT';
      default:
        return 'UDP';
    }
  }

  String get modeLabel {
    switch (mode) {
      case 'proxy':
        return 'Только прокси';
      default:
        return 'Полная работа';
    }
  }

  /// Short explanation shown under the mode selector.
  String get modeDescription {
    switch (mode) {
      case 'proxy':
        return 'Весь трафик устройства принудительно идёт через подключённый прокси. Обход РФ, DNS-трюки и умная маршрутизация при этом выключены.';
      default:
        return 'Работают все настройки: выбранные сервисы идут через прокси, остальное — напрямую, плюс обход блокировок РФ, DNS и защита от DPI.';
    }
  }

  Map<String, dynamic> toEngineSettings() => <String, dynamic>{
        'mode': mode,
        'bypass_ru': bypassRu,
        'bypass_all': bypassAll,
        'bypass_domains': bypassDomains,
        'lan_bypass': lanBypass,
        'adblock': adblock,
        'block_quic': blockQuic,
        'disable_ipv6': disableIpv6,
        'dpi_bypass': dpiBypass,
        'dpi_method': dpiMethod,
        'frag_size': fragSize,
        'kill_switch': killSwitch,
        'block_unencrypted': blockUnencrypted,
        'auto_failover': autoFailover,
        'rotation_secs': rotationSecs,
        'dns': <String, dynamic>{
          'protocol': dnsProtocol,
          'server': dnsServerValue,
          'leak_protection': dnsLeak,
        },
        'check_url': checkUrl,
        'mtu': mtu,
        'udp_over_tcp': udpTcp,
        'ipv6_enabled': !disableIpv6,
      };

  Map<String, dynamic> toVpnOptions() => <String, dynamic>{
        'mtu': mtu,
        'ipv6': !disableIpv6,
        'dns': dnsIp,
        'kill_switch': killSwitch,
        'allowed': splitMode == 'whitelist' ? selectedApps : <String>[],
        'disallowed': splitMode == 'blacklist' ? selectedApps : <String>[],
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode,
        'bypassRu': bypassRu,
        'bypassAll': bypassAll,
        'bypassDomains': bypassDomains,
        'lanBypass': lanBypass,
        'adblock': adblock,
        'blockQuic': blockQuic,
        'disableIpv6': disableIpv6,
        'dpiBypass': dpiBypass,
        'dpiMethod': dpiMethod,
        'fragSize': fragSize,
        'killSwitch': killSwitch,
        'blockUnencrypted': blockUnencrypted,
        'autoFailover': autoFailover,
        'rotationSecs': rotationSecs,
        'dnsProtocol': dnsProtocol,
        'dnsServer': dnsServer,
        'customDns': customDns,
        'dnsLeak': dnsLeak,
        'mtu': mtu,
        'udpTcp': udpTcp,
        'androidMode': androidMode,
        'workers': workers,
        'timeoutMs': timeoutMs,
        'checkUrl': checkUrl,
        'speedCheck': speedCheck,
        'serviceCheck': serviceCheck,
        'anonymityCheck': anonymityCheck,
        'multiHop': multiHop,
        'autostart': autostart,
        'smartProfiles': smartProfiles,
        'splitMode': splitMode,
        'selectedApps': selectedApps,
        'themeMode': themeMode,
        'onboardingDone': onboardingDone,
        'listenPort': listenPort,
        'rootTuning': rootTuning,
        'rootKillSwitch': rootKillSwitch,
        'rootDnsRedirect': rootDnsRedirect,
        'rootAlwaysOn': rootAlwaysOn,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final s = AppSettings();
    int asInt(Object? v, int fallback) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
    bool asBool(Object? v, bool fallback) => v is bool ? v : fallback;
    String asString(Object? v, String fallback) => v is String && v.isNotEmpty ? v : fallback;
    s.mode = switch (asString(json['mode'], s.mode)) {
      'smart' || 'antidpi' || 'full' => 'full',
      'vpn' || 'proxy' => 'proxy',
      _ => 'full',
    };
    s.bypassRu = asBool(json['bypassRu'], s.bypassRu);
    s.bypassAll = asBool(json['bypassAll'], s.bypassAll);
    final bypassDomains = json['bypassDomains'];
    if (bypassDomains is List) {
      s.bypassDomains = bypassDomains
          .map((dynamic e) => e.toString().trim().toLowerCase())
          .where((String e) => e.isNotEmpty)
          .toList();
    }
    s.lanBypass = asBool(json['lanBypass'], s.lanBypass);
    s.adblock = asBool(json['adblock'], s.adblock);
    s.blockQuic = asBool(json['blockQuic'], s.blockQuic);
    s.disableIpv6 = asBool(json['disableIpv6'], s.disableIpv6);
    s.dpiBypass = asBool(json['dpiBypass'], s.dpiBypass);
    s.dpiMethod = asString(json['dpiMethod'], s.dpiMethod);
    s.fragSize = asInt(json['fragSize'], s.fragSize);
    s.killSwitch = asBool(json['killSwitch'], s.killSwitch);
    s.blockUnencrypted = asBool(json['blockUnencrypted'], s.blockUnencrypted);
    s.autoFailover = asBool(json['autoFailover'], s.autoFailover);
    s.rotationSecs = asInt(json['rotationSecs'], s.rotationSecs);
    s.dnsProtocol = asString(json['dnsProtocol'], s.dnsProtocol);
    s.dnsServer = asString(json['dnsServer'], s.dnsServer);
    s.customDns = asString(json['customDns'], s.customDns);
    s.dnsLeak = asBool(json['dnsLeak'], s.dnsLeak);
    s.mtu = asInt(json['mtu'], s.mtu);
    s.udpTcp = asBool(json['udpTcp'], s.udpTcp);
    s.androidMode = asString(json['androidMode'], s.androidMode);
    s.workers = asInt(json['workers'], s.workers);
    s.timeoutMs = asInt(json['timeoutMs'], s.timeoutMs);
    s.checkUrl = asString(json['checkUrl'], s.checkUrl);
    s.speedCheck = asBool(json['speedCheck'], s.speedCheck);
    s.serviceCheck = asBool(json['serviceCheck'], s.serviceCheck);
    s.anonymityCheck = asBool(json['anonymityCheck'], s.anonymityCheck);
    s.multiHop = asBool(json['multiHop'], s.multiHop);
    s.autostart = asBool(json['autostart'], s.autostart);
    s.smartProfiles = asBool(json['smartProfiles'], s.smartProfiles);
    s.splitMode = asString(json['splitMode'], s.splitMode);
    final apps = json['selectedApps'];
    if (apps is List) {
      s.selectedApps = apps.map((dynamic e) => e.toString()).toList();
    }
    s.themeMode = asString(json['themeMode'], s.themeMode);
    // The app now ships two explicit themes; a legacy 'system' value falls
    // back to dark so the toggle in the header always has a clear meaning.
    if (s.themeMode != 'light' && s.themeMode != 'dark') s.themeMode = 'dark';
    s.onboardingDone = asBool(json['onboardingDone'], s.onboardingDone);
    s.listenPort = asInt(json['listenPort'], s.listenPort);
    s.rootTuning = asBool(json['rootTuning'], s.rootTuning);
    s.rootKillSwitch = asBool(json['rootKillSwitch'], s.rootKillSwitch);
    s.rootDnsRedirect = asBool(json['rootDnsRedirect'], s.rootDnsRedirect);
    s.rootAlwaysOn = asBool(json['rootAlwaysOn'], s.rootAlwaysOn);
    return s;
  }

  String encode() => jsonEncode(toJson());

  static AppSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return AppSettings();
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return AppSettings.fromJson(parsed);
    } catch (_) {}
    return AppSettings();
  }
}
