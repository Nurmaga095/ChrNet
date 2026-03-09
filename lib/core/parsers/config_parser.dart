import 'dart:convert';
import '../models/server_config.dart';

class ConfigParser {
  /// Парсит один URI и возвращает ServerConfig или null при ошибке
  static ServerConfig? parse(
    String uri, {
    int? subscriptionOrder,
  }) {
    final trimmed = uri.trim();
    try {
      if (trimmed.startsWith('vless://')) {
        return _parseVless(trimmed, subscriptionOrder: subscriptionOrder);
      }
      if (trimmed.startsWith('vmess://')) {
        return _parseVmess(trimmed, subscriptionOrder: subscriptionOrder);
      }
      if (trimmed.startsWith('trojan://')) {
        return _parseTrojan(trimmed, subscriptionOrder: subscriptionOrder);
      }
      if (trimmed.startsWith('ss://')) {
        return _parseShadowsocks(trimmed, subscriptionOrder: subscriptionOrder);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Парсит несколько URI (подписка — base64 список)
  static List<ServerConfig> parseSubscription(String raw) {
    String decoded = raw.trim();

    // Попытка base64 декодирования
    try {
      decoded = utf8.decode(base64Decode(raw.trim()));
    } catch (_) {
      // Не base64 — пробуем как есть
    }

    final lines = decoded
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final configs = <ServerConfig>[];
    for (int i = 0; i < lines.length; i++) {
      final config = parse(lines[i], subscriptionOrder: i);
      if (config != null) configs.add(config);
    }
    return configs;
  }

  // ─── VLESS ────────────────────────────────────────────────────────────────
  // vless://uuid@host:port?type=tcp&security=tls&sni=example.com#name
  static ServerConfig _parseVless(
    String uri, {
    int? subscriptionOrder,
  }) {
    final withoutScheme = uri.substring('vless://'.length);
    final hashIdx = withoutScheme.lastIndexOf('#');
    final name = hashIdx >= 0
        ? Uri.decodeComponent(withoutScheme.substring(hashIdx + 1))
        : '';
    final main = hashIdx >= 0
        ? withoutScheme.substring(0, hashIdx)
        : withoutScheme;

    final atIdx = main.indexOf('@');
    final uuid = main.substring(0, atIdx);
    final hostPort = main.substring(atIdx + 1);

    final qIdx = hostPort.indexOf('?');
    final hostPortOnly = qIdx >= 0 ? hostPort.substring(0, qIdx) : hostPort;
    final queryStr = qIdx >= 0 ? hostPort.substring(qIdx + 1) : '';

    final (host, port) = _splitHostPort(hostPortOnly);
    final extras = Uri.splitQueryString(queryStr).map(
      (k, v) => MapEntry(k, v),
    );

    return ServerConfig(
      id: _generateId(),
      name: name,
      host: host,
      port: port,
      protocol: 'vless',
      uuid: uuid,
      rawUri: uri,
      extras: Map<String, String>.from(extras),
      addedAt: DateTime.now(),
      subscriptionOrder: subscriptionOrder,
    );
  }

  // ─── VMESS ────────────────────────────────────────────────────────────────
  // vmess://base64(json)
  static ServerConfig _parseVmess(
    String uri, {
    int? subscriptionOrder,
  }) {
    final base64Part = uri.substring('vmess://'.length);
    final json = utf8.decode(base64Decode(_padBase64(base64Part)));
    final map = jsonDecode(json) as Map<String, dynamic>;

    final host = map['add']?.toString() ?? '';
    final port = int.tryParse(map['port']?.toString() ?? '0') ?? 0;
    final uuid = map['id']?.toString() ?? '';
    final name = map['ps']?.toString() ?? '$host:$port';

    final extras = <String, String>{
      if (map['net'] != null) 'type': map['net'].toString(),
      if (map['tls'] != null) 'security': map['tls'].toString(),
      if (map['sni'] != null) 'sni': map['sni'].toString(),
      if (map['path'] != null) 'path': map['path'].toString(),
      if (map['host'] != null) 'host': map['host'].toString(),
      if (map['v'] != null) 'v': map['v'].toString(),
    };

    return ServerConfig(
      id: _generateId(),
      name: name,
      host: host,
      port: port,
      protocol: 'vmess',
      uuid: uuid,
      rawUri: uri,
      extras: extras,
      addedAt: DateTime.now(),
      subscriptionOrder: subscriptionOrder,
    );
  }

  // ─── TROJAN ───────────────────────────────────────────────────────────────
  // trojan://password@host:port?sni=example.com#name
  static ServerConfig _parseTrojan(
    String uri, {
    int? subscriptionOrder,
  }) {
    final withoutScheme = uri.substring('trojan://'.length);
    final hashIdx = withoutScheme.lastIndexOf('#');
    final name = hashIdx >= 0
        ? Uri.decodeComponent(withoutScheme.substring(hashIdx + 1))
        : '';
    final main = hashIdx >= 0
        ? withoutScheme.substring(0, hashIdx)
        : withoutScheme;

    final atIdx = main.indexOf('@');
    final password = main.substring(0, atIdx);
    final hostPort = main.substring(atIdx + 1);

    final qIdx = hostPort.indexOf('?');
    final hostPortOnly = qIdx >= 0 ? hostPort.substring(0, qIdx) : hostPort;
    final queryStr = qIdx >= 0 ? hostPort.substring(qIdx + 1) : '';

    final (host, port) = _splitHostPort(hostPortOnly);
    final extras = Map<String, String>.from(Uri.splitQueryString(queryStr));

    return ServerConfig(
      id: _generateId(),
      name: name,
      host: host,
      port: port,
      protocol: 'trojan',
      uuid: password,
      rawUri: uri,
      extras: extras,
      addedAt: DateTime.now(),
      subscriptionOrder: subscriptionOrder,
    );
  }

  // ─── SHADOWSOCKS ──────────────────────────────────────────────────────────
  // ss://base64(method:password)@host:port#name
  static ServerConfig _parseShadowsocks(
    String uri, {
    int? subscriptionOrder,
  }) {
    final withoutScheme = uri.substring('ss://'.length);
    final hashIdx = withoutScheme.lastIndexOf('#');
    final name = hashIdx >= 0
        ? Uri.decodeComponent(withoutScheme.substring(hashIdx + 1))
        : '';
    final main = hashIdx >= 0
        ? withoutScheme.substring(0, hashIdx)
        : withoutScheme;

    final atIdx = main.lastIndexOf('@');
    String credentials;
    String hostPort;

    if (atIdx >= 0) {
      credentials = main.substring(0, atIdx);
      hostPort = main.substring(atIdx + 1);
    } else {
      // Старый формат: base64(method:password@host:port)
      final decoded = utf8.decode(base64Decode(_padBase64(main)));
      final parts = decoded.split('@');
      credentials = parts[0];
      hostPort = parts[1];
    }

    // credentials может быть base64(method:password) или method:password
    String methodPass = credentials;
    try {
      methodPass = utf8.decode(base64Decode(_padBase64(credentials)));
    } catch (_) {}

    final colonIdx = methodPass.indexOf(':');
    final method = colonIdx >= 0 ? methodPass.substring(0, colonIdx) : '';
    final password = colonIdx >= 0 ? methodPass.substring(colonIdx + 1) : methodPass;

    final (host, port) = _splitHostPort(hostPort);

    return ServerConfig(
      id: _generateId(),
      name: name,
      host: host,
      port: port,
      protocol: 'ss',
      uuid: password,
      rawUri: uri,
      extras: {'method': method},
      addedAt: DateTime.now(),
      subscriptionOrder: subscriptionOrder,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────
  static (String host, int port) _splitHostPort(String hostPort) {
    // IPv6: [::1]:8080
    if (hostPort.startsWith('[')) {
      final bracketEnd = hostPort.indexOf(']');
      final host = hostPort.substring(1, bracketEnd);
      final port = int.tryParse(
            hostPort.substring(bracketEnd + 2),
          ) ??
          443;
      return (host, port);
    }
    final idx = hostPort.lastIndexOf(':');
    if (idx < 0) return (hostPort, 443);
    final host = hostPort.substring(0, idx);
    final port = int.tryParse(hostPort.substring(idx + 1)) ?? 443;
    return (host, port);
  }

  static String _padBase64(String s) {
    final rem = s.length % 4;
    if (rem == 0) return s;
    return s + '=' * (4 - rem);
  }

  static int _idCounter = 0;

  static String _generateId() {
    _idCounter = (_idCounter + 1) & 0xFFFFF;
    return '${DateTime.now().microsecondsSinceEpoch}_${_idCounter.toRadixString(16)}';
  }
}
