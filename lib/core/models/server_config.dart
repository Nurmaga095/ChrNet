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

  String get displayName => name.isNotEmpty ? name : '$protocol://$host:$port';
  String get protocolUpper => protocol.toUpperCase();

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
