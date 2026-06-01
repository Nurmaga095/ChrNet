import 'dart:convert';

class ServerConfig {
  final String id;
  final String name;
  final String host;
  final int port;
  final String protocol;
  final String uuid;
  final String rawUri;
  final Map<String, String> extras;
  final DateTime addedAt;
  final int? ping;
  final int? subscriptionOrder;
  String? subscriptionId;

  ServerConfig({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.protocol,
    required this.uuid,
    required this.rawUri,
    required this.extras,
    required this.addedAt,
    this.ping,
    this.subscriptionOrder,
    this.subscriptionId,
  });

  String get displayName {
    if (name.isNotEmpty) return name;
    if (protocol == 'json') {
      final sourceProtocol = _sourceProtocolLabel;
      if (sourceProtocol != null && sourceProtocol.isNotEmpty) {
        return '${sourceProtocol.toUpperCase()} JSON';
      }
      return 'JSON://$host:$port';
    }
    return '$protocol://$host:$port';
  }

  String get protocolUpper {
    if (protocol != 'json') return protocol.toUpperCase();

    final sourceProtocol = _sourceProtocolLabel;
    if (sourceProtocol != null && sourceProtocol.isNotEmpty) {
      return '${sourceProtocol.toUpperCase()} | JSON';
    }
    return 'JSON';
  }

  String? get _sourceProtocolLabel {
    final explicit = extras['sourceProtocol']?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    final rawConfigJson = extras['configJson'];
    if (rawConfigJson == null || rawConfigJson.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(rawConfigJson);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final outbounds = decoded['outbounds'];
      if (outbounds is! List) {
        return null;
      }

      for (final outbound in outbounds) {
        if (outbound is! Map) continue;
        final protocol = outbound['protocol']?.toString().trim().toLowerCase();
        if (protocol == null || protocol.isEmpty) continue;
        if ({
          'freedom',
          'blackhole',
          'dns',
          'socks',
          'http',
          'loopback',
        }.contains(protocol)) {
          continue;
        }
        return protocol;
      }
    } catch (_) {}

    return null;
  }

  ServerConfig copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? protocol,
    String? uuid,
    String? rawUri,
    Map<String, String>? extras,
    DateTime? addedAt,
    int? ping,
    int? subscriptionOrder,
    String? subscriptionId,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      uuid: uuid ?? this.uuid,
      rawUri: rawUri ?? this.rawUri,
      extras: extras ?? this.extras,
      addedAt: addedAt ?? this.addedAt,
      ping: ping ?? this.ping,
      subscriptionOrder: subscriptionOrder ?? this.subscriptionOrder,
      subscriptionId: subscriptionId ?? this.subscriptionId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'protocol': protocol,
        'uuid': uuid,
        'rawUri': rawUri,
        'extras': extras,
        'addedAt': addedAt.toIso8601String(),
        if (ping != null) 'ping': ping,
        if (subscriptionOrder != null) 'subscriptionOrder': subscriptionOrder,
        if (subscriptionId != null) 'subscriptionId': subscriptionId,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
        port: j['port'] as int,
        protocol: j['protocol'] as String,
        uuid: j['uuid'] as String,
        rawUri: j['rawUri'] as String,
        extras: Map<String, String>.from(j['extras'] as Map),
        addedAt: DateTime.parse(j['addedAt'] as String),
        ping: j['ping'] as int?,
        subscriptionOrder: (j['subscriptionOrder'] as num?)?.toInt(),
        subscriptionId: j['subscriptionId'] as String?,
      );
}
