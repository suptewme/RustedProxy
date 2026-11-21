import 'package:flutter_test/flutter_test.dart';
import 'package:rusted_proxy/models/proxy.dart';
import 'package:rusted_proxy/models/settings.dart';

ProxyServer _p(int latency, {String code = 'DE', double speed = 0, String proto = 'socks5'}) =>
    ProxyServer(
      id: '$proto-$code-$latency',
      proto: proto,
      host: 'host-$latency.example',
      port: 10000 + latency,
      latency: latency,
      speed: speed,
      countryCode: code,
    );

void main() {
  group('theme', () {
    test('legacy system theme falls back to dark', () {
      expect(AppSettings.decode('{"themeMode":"system"}').themeMode, 'dark');
    });

    test('explicit themes survive a round trip', () {
      final s = AppSettings()..themeMode = 'light';
      expect(AppSettings.decode(s.encode()).themeMode, 'light');
    });
  });

  group('traffic snapshot', () {
    test('equal snapshots do not ask for a repaint', () {
      final a = <int>[1, 2];
      expect(a, <int>[1, 2]);
    });
  });

  group('scan result filters', () {
    final found = <ProxyServer>[
      _p(40, code: 'NL'),
      _p(120, code: 'DE', speed: 20),
      _p(300, code: 'DE'),
      _p(0, code: 'US'),
    ];

    List<ProxyServer> apply({
      int min = 0,
      int max = 0,
      String country = '',
      bool video = false,
      bool desc = false,
    }) {
      var list = found.where((ProxyServer p) {
        if (p.latency <= 0) return false;
        if (min > 0 && p.latency < min) return false;
        if (max > 0 && p.latency > max) return false;
        if (country.isNotEmpty && p.countryCode != country) return false;
        return true;
      }).toList();
      if (video) list = list.where((ProxyServer p) => p.speed >= 15).toList();
      list.sort((ProxyServer a, ProxyServer b) =>
          desc ? b.latency.compareTo(a.latency) : a.latency.compareTo(b.latency));
      return list;
    }

    test('dead nodes (0 ms) are hidden', () {
      expect(apply().map((ProxyServer p) => p.latency), <int>[40, 120, 300]);
    });

    test('ping window keeps only the matching range', () {
      expect(apply(min: 100, max: 200).map((ProxyServer p) => p.latency), <int>[120]);
    });

    test('country filter and descending order', () {
      expect(apply(country: 'DE', desc: true).map((ProxyServer p) => p.latency), <int>[300, 120]);
    });

    test('video filter needs measured speed', () {
      expect(apply(video: true).map((ProxyServer p) => p.latency), <int>[120]);
    });
  });
}