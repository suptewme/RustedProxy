class LogItem {
  LogItem({
    required this.seq,
    required this.ts,
    required this.level,
    required this.msg,
  });

  final int seq;
  final DateTime ts;
  final String level;
  final String msg;

  factory LogItem.fromJson(Map<String, dynamic> json) {
    final millis = json['ts'] is num ? (json['ts'] as num).toInt() : 0;
    return LogItem(
      seq: json['seq'] is num ? (json['seq'] as num).toInt() : 0,
      ts: DateTime.fromMillisecondsSinceEpoch(millis),
      level: (json['level'] ?? 'INFO').toString(),
      msg: (json['msg'] ?? '').toString(),
    );
  }

  String get timeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}';
  }
}
