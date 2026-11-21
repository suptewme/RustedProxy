class ProxyServer {
  ProxyServer({
    required this.id,
    required this.proto,
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
    this.cipher = '',
    this.uuid = '',
    this.sni = '',
    this.tls = false,
    this.name = '',
    this.country = '',
    this.countryCode = '',
    this.city = '',
    this.flag = '🌐',
    this.latency = 0,
    this.speed = 0,
    this.encrypted = false,
    this.anonymity = '',
    this.tags = const <String>[],
    this.source = '',
    this.raw = '',
  });

  final String id;
  final String proto;
  final String host;
  final int port;
  final String username;
  final String password;
  final String cipher;
  final String uuid;
  final String sni;
  final bool tls;
  final String name;
  final String country;
  final String countryCode;
  final String city;
  final String flag;
  final int latency;
  final double speed;
  final bool encrypted;
  final String anonymity;
  final List<String> tags;
  final String source;
  final String raw;

  String get endpoint => host.contains(':') ? '[$host]:$port' : '$host:$port';

  String get protoLabel {
    switch (proto.toLowerCase()) {
      case 'socks5':
        return 'SOCKS5';
      case 'socks4':
      case 'socks4a':
        return 'SOCKS4';
      case 'http':
        return 'HTTP';
      case 'https':
        return 'HTTPS';
      case 'ss':
      case 'shadowsocks':
        return 'Shadowsocks';
      case 'trojan':
        return 'Trojan';
      case 'vless':
        return 'VLESS';
      case 'vmess':
        return 'VMess';
      default:
        return proto.toUpperCase();
    }
  }

  String get securityLabel {
    if (tls) return 'TLS';
    if (proto == 'ss') return 'AEAD';
    if (proto == 'https') return 'TLS';
    return '';
  }

  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    if (country.isNotEmpty) return '$flag $country';
    return endpoint;
  }

  String get displayLocation {
    if (city.isNotEmpty && country.isNotEmpty) return '$flag $country, $city';
    if (country.isNotEmpty) return '$flag $country';
    return flag;
  }

  String get latencyLabel => latency > 0 ? '$latency мс' : '—';

  Map<String, dynamic> toRust() => <String, dynamic>{
        'id': id,
        'proto': proto,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'cipher': cipher,
        'uuid': uuid,
        'sni': sni,
        'tls': tls,
        'name': name,
        'country': country,
        'country_code': countryCode,
        'city': city,
        'flag': flag,
        'latency': latency,
        'speed': speed,
        'encrypted': encrypted,
        'anonymity': anonymity,
        'tags': tags,
        'raw': raw,
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...toRust(),
        'countryCode': countryCode,
        'source': source,
      };

  factory ProxyServer.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}') ?? 0;
    }

    double asDouble(Object? v) {
      if (v is num) return v.toDouble();
      return double.tryParse('${v ?? ''}') ?? 0;
    }

    return ProxyServer(
      id: (json['id'] ?? '').toString(),
      proto: (json['proto'] ?? 'socks5').toString(),
      host: (json['host'] ?? '').toString(),
      port: asInt(json['port']),
      username: (json['username'] ?? '').toString(),
      password: (json['password'] ?? '').toString(),
      cipher: (json['cipher'] ?? '').toString(),
      uuid: (json['uuid'] ?? '').toString(),
      sni: (json['sni'] ?? '').toString(),
      tls: json['tls'] == true,
      name: (json['name'] ?? '').toString(),
      country: (json['country'] ?? '').toString(),
      countryCode: (json['countryCode'] ?? json['country_code'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      flag: (json['flag'] ?? '🌐').toString(),
      latency: asInt(json['latency']),
      speed: asDouble(json['speed']),
      encrypted: json['encrypted'] == true,
      anonymity: (json['anonymity'] ?? '').toString(),
      tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      source: (json['source'] ?? '').toString(),
      raw: (json['raw'] ?? '').toString(),
    );
  }

  ProxyServer copyWith({
    String? name,
    String? country,
    String? countryCode,
    String? city,
    String? flag,
    int? latency,
    double? speed,
    bool? encrypted,
    String? anonymity,
    List<String>? tags,
  }) {
    return ProxyServer(
      id: id,
      proto: proto,
      host: host,
      port: port,
      username: username,
      password: password,
      cipher: cipher,
      uuid: uuid,
      sni: sni,
      tls: tls,
      name: name ?? this.name,
      country: country ?? this.country,
      countryCode: countryCode ?? this.countryCode,
      city: city ?? this.city,
      flag: flag ?? this.flag,
      latency: latency ?? this.latency,
      speed: speed ?? this.speed,
      encrypted: encrypted ?? this.encrypted,
      anonymity: anonymity ?? this.anonymity,
      tags: tags ?? this.tags,
      source: source,
      raw: raw,
    );
  }

  String get key => '$proto|$host|$port';

  @override
  String toString() => 'ProxyServer($protoLabel $endpoint)';
}
