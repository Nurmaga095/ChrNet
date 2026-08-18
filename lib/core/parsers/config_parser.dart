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
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Schemes the app used to accept, kept only so import can tell the user
  /// "this key is no longer supported" instead of silently skipping the line.
  static const List<String> retiredSchemes = [
    'vmess://',
    'trojan://',
    'ss://',
    'hysteria2://',
    'hysteria://',
    'hy2://',
  ];

  static bool isRetiredScheme(String value) {
    final lower = value.trim().toLowerCase();
    return retiredSchemes.any(lower.startsWith);
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
      "vless:\\/\\/[^\\s<>\"'`\\\\]+",
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
    return value.toLowerCase().startsWith('vless://');
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

    Map<String, dynamic>? proxyOutbound;
    ({String host, int port})? endpoint;
    for (final entry in outboundsDynamic) {
      if (entry is! Map<String, dynamic> || !_isProxyOutbound(entry)) {
        continue;
      }
      final candidateEndpoint = _extractEndpoint(entry);
      if (candidateEndpoint == null) {
        continue;
      }
      proxyOutbound = entry;
      endpoint = candidateEndpoint;
      break;
    }

    if (proxyOutbound == null || endpoint == null) {
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

  /// The core only carries VLESS now, so a template whose proxy outbound is
  /// anything else would import fine and then fail at connect time. Treating it
  /// as "no proxy outbound found" makes the template be rejected at import.
  static bool _isProxyOutbound(Map<String, dynamic> outbound) {
    return outbound['protocol']?.toString().trim().toLowerCase() == 'vless';
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

    return '';
  }

  static int _idCounter = 0;

  static String _generateId() {
    _idCounter = (_idCounter + 1) & 0xFFFFF;
    return '${DateTime.now().microsecondsSinceEpoch}_${_idCounter.toRadixString(16)}';
  }
}
