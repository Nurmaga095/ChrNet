import 'dart:convert';
import '../models/server_config.dart';

class ConfigParser {
  /// Парсит один URI и возвращает ServerConfig или null при ошибке
  static ServerConfig? parse(String uri, {int? subscriptionOrder}) {
    final trimmed = uri.trim();
    final lower = trimmed.toLowerCase();
    try {
      if (_looksLikeJson(trimmed)) {
        final configs = _parseJsonConfigs(
          trimmed,
          subscriptionOrderOffset: subscriptionOrder,
        );
        if (configs.isNotEmpty) {
          return configs.first;
        }
      }
      if (lower.startsWith('vless://')) {
        return _parseVless(trimmed, subscriptionOrder: subscriptionOrder);
      }
      if (lower.startsWith('vmess://')) {
        return _parseVmess(trimmed, subscriptionOrder: subscriptionOrder);
      }
      if (lower.startsWith('trojan://')) {
        return _parseTrojan(trimmed, subscriptionOrder: subscriptionOrder);
      }
      if (lower.startsWith('ss://')) {
        return _parseShadowsocks(trimmed, subscriptionOrder: subscriptionOrder);
      }
      if (lower.startsWith('hysteria2://') || lower.startsWith('hy2://')) {
        return _parseHysteria2(trimmed, subscriptionOrder: subscriptionOrder);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Парсит произвольный текст, который может содержать URI или JSON-конфиги.
  static List<ServerConfig> parseText(String raw, {bool tryBase64 = false}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    if (_looksLikeJson(trimmed)) {
      return _parseJsonConfigs(trimmed);
    }

    String decoded = trimmed;
    if (tryBase64) {
      try {
        decoded = utf8.decode(base64Decode(trimmed));
      } catch (_) {
        decoded = trimmed;
      }

      if (_looksLikeJson(decoded.trim())) {
        return _parseJsonConfigs(decoded.trim());
      }
    }

    final configs = <ServerConfig>[];
    final candidates = _extractUriCandidates(decoded);
    for (int i = 0; i < candidates.length; i++) {
      final config = parse(candidates[i], subscriptionOrder: i);
      if (config != null) configs.add(config);
    }
    return configs;
  }

  /// Парсит несколько URI (подписка — base64 список)
  static List<ServerConfig> parseSubscription(String raw) {
    return parseText(raw, tryBase64: true);
  }

  // ─── VLESS ────────────────────────────────────────────────────────────────
  // vless://uuid@host:port?type=tcp&security=tls&sni=example.com#name
  static ServerConfig _parseVless(String uri, {int? subscriptionOrder}) {
    final withoutScheme = uri.substring('vless://'.length);
    final hashIdx = withoutScheme.lastIndexOf('#');
    final name = hashIdx >= 0
        ? Uri.decodeComponent(withoutScheme.substring(hashIdx + 1))
        : '';
    final main =
        hashIdx >= 0 ? withoutScheme.substring(0, hashIdx) : withoutScheme;

    final atIdx = main.indexOf('@');
    final uuid = main.substring(0, atIdx);
    final hostPort = main.substring(atIdx + 1);

    final qIdx = hostPort.indexOf('?');
    final hostPortOnly = qIdx >= 0 ? hostPort.substring(0, qIdx) : hostPort;
    final queryStr = qIdx >= 0 ? hostPort.substring(qIdx + 1) : '';

    final (host, port) = _splitHostPort(hostPortOnly);
    final extras = Uri.splitQueryString(queryStr).map((k, v) => MapEntry(k, v));

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
  static ServerConfig _parseVmess(String uri, {int? subscriptionOrder}) {
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
  static ServerConfig _parseTrojan(String uri, {int? subscriptionOrder}) {
    final withoutScheme = uri.substring('trojan://'.length);
    final hashIdx = withoutScheme.lastIndexOf('#');
    final name = hashIdx >= 0
        ? Uri.decodeComponent(withoutScheme.substring(hashIdx + 1))
        : '';
    final main =
        hashIdx >= 0 ? withoutScheme.substring(0, hashIdx) : withoutScheme;

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
  static ServerConfig _parseShadowsocks(String uri, {int? subscriptionOrder}) {
    final withoutScheme = uri.substring('ss://'.length);
    final hashIdx = withoutScheme.lastIndexOf('#');
    final name = hashIdx >= 0
        ? Uri.decodeComponent(withoutScheme.substring(hashIdx + 1))
        : '';
    final main =
        hashIdx >= 0 ? withoutScheme.substring(0, hashIdx) : withoutScheme;

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
    final password =
        colonIdx >= 0 ? methodPass.substring(colonIdx + 1) : methodPass;

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

  // ─── HYSTERIA2 ───────────────────────────────────────────────────────────
  // hysteria2://password@host:port?sni=example.com&insecure=1#name
  static ServerConfig _parseHysteria2(String uri, {int? subscriptionOrder}) {
    final lower = uri.toLowerCase();
    final scheme = lower.startsWith('hy2://') ? 'hy2://' : 'hysteria2://';
    final withoutScheme = uri.substring(scheme.length);
    final hashIdx = withoutScheme.lastIndexOf('#');
    final name = hashIdx >= 0
        ? Uri.decodeComponent(withoutScheme.substring(hashIdx + 1))
        : '';
    final main =
        hashIdx >= 0 ? withoutScheme.substring(0, hashIdx) : withoutScheme;

    final atIdx = main.indexOf('@');
    final password =
        atIdx >= 0 ? Uri.decodeComponent(main.substring(0, atIdx)) : '';
    final hostPort = atIdx >= 0 ? main.substring(atIdx + 1) : main;

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
      protocol: 'hysteria2',
      uuid: password,
      rawUri: uri,
      extras: extras,
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
      final port = int.tryParse(hostPort.substring(bracketEnd + 2)) ?? 443;
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

  static List<String> _extractUriCandidates(String text) {
    final decoded = _decodeEmbeddedUriText(text);
    final candidates = <String>[];
    final seen = <String>{};

    void addCandidate(String value) {
      final candidate = _trimUriCandidate(value);
      if (candidate.isEmpty || !seen.add(candidate)) return;
      candidates.add(candidate);
    }

    for (final line in decoded.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (_startsWithSupportedScheme(trimmed)) {
        addCandidate(trimmed);
      }
    }

    final matcher = RegExp(
      "(?:vless|vmess|trojan|ss|hysteria2|hy2):\\/\\/[^\\s<>\"'`\\\\]+",
      caseSensitive: false,
    );
    for (final match in matcher.allMatches(decoded)) {
      addCandidate(match.group(0) ?? '');
    }

    return candidates;
  }

  static String _decodeEmbeddedUriText(String text) {
    return text
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\u003d', '=')
        .replaceAll(r'\u003D', '=')
        .replaceAll(r'\u0023', '#')
        .replaceAll(r'\u003f', '?')
        .replaceAll(r'\u003F', '?')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&#x22;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'");
  }

  static String _trimUriCandidate(String value) {
    return value
        .trim()
        .replaceAll(RegExp(r'[),.;\]}]+$'), '')
        .replaceAll('&amp;', '&');
  }

  static bool _startsWithSupportedScheme(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('vless://') ||
        lower.startsWith('vmess://') ||
        lower.startsWith('trojan://') ||
        lower.startsWith('ss://') ||
        lower.startsWith('hysteria2://') ||
        lower.startsWith('hy2://');
  }

  static bool _looksLikeJson(String text) {
    final trimmed = text.trimLeft();
    return trimmed.startsWith('{') || trimmed.startsWith('[');
  }

  static List<ServerConfig> _parseJsonConfigs(
    String raw, {
    int? subscriptionOrderOffset,
  }) {
    final decoded = jsonDecode(raw);
    final items = switch (decoded) {
      final List<dynamic> values => values,
      final Map<String, dynamic> value => <dynamic>[value],
      _ => const <dynamic>[],
    };

    final configs = <ServerConfig>[];
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map<String, dynamic>) continue;
      final config = _parseJsonConfig(
        item,
        subscriptionOrder:
            subscriptionOrderOffset != null ? subscriptionOrderOffset + i : i,
      );
      if (config != null) {
        configs.add(config);
      }
    }
    return configs;
  }

  static ServerConfig? _parseJsonConfig(
    Map<String, dynamic> config, {
    int? subscriptionOrder,
  }) {
    final outboundsDynamic = config['outbounds'];
    if (outboundsDynamic is! List) {
      return null;
    }

    final proxyOutbound = outboundsDynamic.cast<dynamic>().firstWhere(
          (entry) => entry is Map<String, dynamic> && _isProxyOutbound(entry),
          orElse: () => const <String, dynamic>{},
        );
    if (proxyOutbound is! Map<String, dynamic> || proxyOutbound.isEmpty) {
      return null;
    }

    final endpoint = _extractEndpoint(proxyOutbound);
    if (endpoint == null) {
      return null;
    }

    final protocol = proxyOutbound['protocol']?.toString().trim().toLowerCase();
    final canonicalConfig = jsonEncode(config);
    final remark = config['remarks']?.toString().trim() ?? '';
    final meta = config['meta'];
    final serverDescription = meta is Map<String, dynamic>
        ? meta['serverDescription']?.toString().trim()
        : null;

    return ServerConfig(
      id: _generateId(),
      name: remark,
      host: endpoint.host,
      port: endpoint.port,
      protocol: 'json',
      uuid: _extractCredential(proxyOutbound),
      rawUri: canonicalConfig,
      extras: <String, String>{
        'configJson': canonicalConfig,
        if (protocol != null && protocol.isNotEmpty) 'sourceProtocol': protocol,
        if (serverDescription != null && serverDescription.isNotEmpty)
          'serverDescription': serverDescription,
      },
      addedAt: DateTime.now(),
      subscriptionOrder: subscriptionOrder,
    );
  }

  static bool _isProxyOutbound(Map<String, dynamic> outbound) {
    final protocol = outbound['protocol']?.toString().trim().toLowerCase();
    if (protocol == null || protocol.isEmpty) {
      return false;
    }
    return !{
      'freedom',
      'blackhole',
      'dns',
      'socks',
      'http',
      'loopback',
    }.contains(protocol);
  }

  static ({String host, int port})? _extractEndpoint(
    Map<String, dynamic> outbound,
  ) {
    final settings = outbound['settings'];
    if (settings is! Map<String, dynamic>) {
      return null;
    }

    final vnext = settings['vnext'];
    if (vnext is List && vnext.isNotEmpty) {
      final first = vnext.first;
      if (first is Map<String, dynamic>) {
        final host = first['address']?.toString().trim() ?? '';
        final port = int.tryParse(first['port']?.toString() ?? '') ?? 0;
        if (host.isNotEmpty && port > 0) {
          return (host: host, port: port);
        }
      }
    }

    final servers = settings['servers'];
    if (servers is List && servers.isNotEmpty) {
      final first = servers.first;
      if (first is Map<String, dynamic>) {
        final host = first['address']?.toString().trim() ?? '';
        final port = int.tryParse(first['port']?.toString() ?? '') ?? 0;
        if (host.isNotEmpty && port > 0) {
          return (host: host, port: port);
        }
      }
    }

    final host = settings['address']?.toString().trim() ?? '';
    final port = int.tryParse(settings['port']?.toString() ?? '') ?? 0;
    if (host.isNotEmpty && port > 0) {
      return (host: host, port: port);
    }

    return null;
  }

  static String _extractCredential(Map<String, dynamic> outbound) {
    final settings = outbound['settings'];
    if (settings is! Map<String, dynamic>) {
      return '';
    }

    final vnext = settings['vnext'];
    if (vnext is List && vnext.isNotEmpty) {
      final first = vnext.first;
      if (first is Map<String, dynamic>) {
        final users = first['users'];
        if (users is List &&
            users.isNotEmpty &&
            users.first is Map<String, dynamic>) {
          final user = users.first as Map<String, dynamic>;
          return user['id']?.toString() ?? user['email']?.toString() ?? '';
        }
      }
    }

    final servers = settings['servers'];
    if (servers is List &&
        servers.isNotEmpty &&
        servers.first is Map<String, dynamic>) {
      final server = servers.first as Map<String, dynamic>;
      return server['password']?.toString() ??
          server['email']?.toString() ??
          '';
    }

    return '';
  }

  static int _idCounter = 0;

  static String _generateId() {
    _idCounter = (_idCounter + 1) & 0xFFFFF;
    return '${DateTime.now().microsecondsSinceEpoch}_${_idCounter.toRadixString(16)}';
  }
}
