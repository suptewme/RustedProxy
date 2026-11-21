import 'proxy.dart';

class ScanSnapshot {
  ScanSnapshot({
    this.running = false,
    this.phase = 'idle',
    this.checked = 0,
    this.total = 0,
    this.skipped = 0,
    this.elapsed = 0,
    this.found = const <ProxyServer>[],
    this.errors = const <String>[],
    this.sources = const <Map<String, dynamic>>[],
  });

  final bool running;
  final String phase;
  final int checked;
  final int total;
  final int skipped;
  final int elapsed;
  final List<ProxyServer> found;
  final List<String> errors;
  final List<Map<String, dynamic>> sources;

  double get progress => total <= 0 ? 0 : (checked / total).clamp(0.0, 1.0);

  String get phaseLabel {
    switch (phase) {
      case 'fetching':
        return 'Скачивание баз прокси…';
      case 'checking':
        return 'Проверка кандидатов…';
      case 'done':
        return 'Готово';
      default:
        return 'Подготовка…';
    }
  }

  factory ScanSnapshot.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return ScanSnapshot(
      running: json['running'] == true,
      phase: (json['phase'] ?? 'idle').toString(),
      checked: asInt(json['checked']),
      total: asInt(json['total']),
      skipped: asInt(json['skipped']),
      elapsed: asInt(json['elapsed']),
      found: (json['found'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(ProxyServer.fromJson)
          .toList(growable: false),
      errors: (json['errors'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      sources: (json['sources'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false),
    );
  }
}
