import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rusted_proxy/models/proxy.dart';
import 'package:rusted_proxy/models/settings.dart';

void main() {
  group('AppSettings', () {
    test('settings survive a JSON round trip', () {
      final settings = AppSettings()
        ..mode = 'proxy'
        ..bypassRu = false
        ..bypassAll = true
        ..bypassDomains = <String>['example.com', '*.example.org']
        ..adblock = false
        ..mtu = 1350
        ..dnsProtocol = 'dot'
        ..dnsServer = 'google'
        ..splitMode = 'whitelist'
        ..selectedApps = <String>['org.mozilla.firefox', 'com.discord'];

      final restored = AppSettings.decode(settings.encode());

      expect(restored.mode, 'proxy');
      expect(restored.bypassRu, isFalse);
      expect(restored.bypassAll, isTrue);
      expect(restored.bypassDomains, <String>['example.com', '*.example.org']);
      expect(restored.adblock, isFalse);
      expect(restored.mtu, 1350);
      expect(restored.dnsProtocol, 'dot');
      expect(restored.dnsServer, 'google');
      expect(restored.splitMode, 'whitelist');
      expect(restored.selectedApps, <String>['org.mozilla.firefox', 'com.discord']);
    });

    test('legacy modes migrate to the two supported ones', () {
      expect(AppSettings.decode('{"mode":"antidpi"}').mode, 'full');
      expect(AppSettings.decode('{"mode":"smart"}').mode, 'full');
      expect(AppSettings.decode('{"mode":"vpn"}').mode, 'proxy');
      expect(AppSettings.decode('{"mode":"proxy"}').mode, 'proxy');
      expect(AppSettings.decode('{"mode":"full"}').mode, 'full');
    });

    test('unknown modes fall back to the full feature set', () {
      expect(AppSettings.decode('{"mode":"nonsense"}').mode, 'full');
      expect(AppSettings().mode, 'full');
    });

    test('mode labels and descriptions match the UI contract', () {
      final full = AppSettings()..mode = 'full';
      expect(full.modeLabel, 'Полная работа');
      expect(full.modeDescription, contains('обход блокировок РФ'));

      final proxy = AppSettings()..mode = 'proxy';
      expect(proxy.modeLabel, 'Только прокси');
      expect(proxy.modeDescription, contains('Весь трафик'));
    });

    test('engine settings expose the new routing fields', () {
      final settings = AppSettings()
        ..mode = 'full'
        ..bypassRu = true
        ..bypassAll = false
        ..bypassDomains = <String>['example.net'];

      final engine = settings.toEngineSettings();

      expect(engine['mode'], 'full');
      expect(engine['bypass_ru'], isTrue);
      expect(engine['bypass_all'], isFalse);
      expect(engine['bypass_domains'], <String>['example.net']);
      final dns = engine['dns'] as Map<String, dynamic>;
      expect(dns['protocol'], 'doh');
      expect(dns['server'], contains('cloudflare'));
    });

    test('DNS server value follows the chosen protocol', () {
      final doh = AppSettings()..dnsProtocol = 'doh'..dnsServer = 'quad9';
      expect(doh.dnsServerValue, 'https://dns.quad9.net/dns-query');
      expect(doh.dnsIp, '9.9.9.9');

      final dot = AppSettings()..dnsProtocol = 'dot'..dnsServer = 'google';
      expect(dot.dnsServerValue, '8.8.8.8');
      expect(dot.dnsLabel, 'DoT');

      final custom = AppSettings()
        ..dnsProtocol = 'doh'
        ..dnsServer = 'custom'
        ..customDns = 'dns.example.com';
      expect(custom.dnsServerValue, 'https://dns.example.com/dns-query');
    });

    test('corrupted settings never throw', () {
      expect(AppSettings.decode('not json').mode, 'full');
      expect(AppSettings.decode('{"mtu":"broken"}').mtu, greaterThan(0));
      expect(AppSettings.decode(null).adblock, isTrue);
    });
  });

  group('ProxyServer', () {
    test('maps between link fields and the Rust payload', () {
      final proxy = ProxyServer(
        id: 'test',
        proto: 'trojan',
        host: 'example.com',
        port: 443,
        uuid: 'secret',
        sni: 'example.com',
        tls: true,
        name: 'Test node',
        country: 'Netherlands',
        countryCode: 'NL',
        flag: '🇳🇱',
        latency: 42,
      );

      final restored = ProxyServer.fromJson(proxy.toJson());

      expect(restored.endpoint, 'example.com:443');
      expect(restored.protoLabel, 'Trojan');
      expect(restored.countryCode, 'NL');
      expect(restored.latencyLabel, '42 мс');
      expect(restored.securityLabel, 'TLS');
      expect(restored.toRust()['host'], 'example.com');
    });

    test('key is derived from protocol, host and port', () {
      final a = ProxyServer(id: 'a', proto: 'socks5', host: '1.2.3.4', port: 1080);
      final b = ProxyServer(id: 'b', proto: 'socks5', host: '1.2.3.4', port: 1080);
      final c = ProxyServer(id: 'c', proto: 'socks5', host: '1.2.3.4', port: 1081);
      expect(a.key, b.key);
      expect(a.key, isNot(c.key));
    });

    test('missing latency is rendered as a dash', () {
      expect(
        ProxyServer(id: 'x', proto: 'socks5', host: 'x', port: 1).latencyLabel,
        '—',
      );
    });

    test('copyWith keeps identity and updates the ping', () {
      final original = ProxyServer(
        id: 'node',
        proto: 'socks5',
        host: '1.2.3.4',
        port: 1080,
        name: 'node',
        latency: 100,
      );
      final updated = original.copyWith(latency: 25);
      expect(updated.key, original.key);
      expect(updated.latency, 25);
      expect(updated.name, 'node');
    });
  });

  group('saved list decoding', () {
    test('tolerates malformed entries', () {
      final raw = jsonEncode(<dynamic>[
        <String, dynamic>{'proto': 'socks5', 'host': '1.1.1.1', 'port': 1080},
        'garbage',
        42,
      ]);
      final decoded = jsonDecode(raw);
      expect(decoded, isA<List<dynamic>>());
      final servers = (decoded as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(ProxyServer.fromJson)
          .toList();
      expect(servers, hasLength(1));
      expect(servers.first.endpoint, '1.1.1.1:1080');
    });
  });
}
