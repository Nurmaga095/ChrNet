import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/server_config.dart';
import '../parsers/config_parser.dart';
import 'device_service.dart';

enum ImportResult { success, noConfig, error }

class ImportResponse {
  final ImportResult result;
  final List<ServerConfig> configs;
  final String? error;
  final List<String> dnsServers;

  // Данные подписки из заголовка subscription-userinfo
  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final int? expireTimestamp;

  // URL подписки, если импорт был из URL
  final String? subscriptionUrl;

  // Строки описания из тела подписки или заголовка announce
  final List<String> description;

  // Название подписки из заголовка profile-title
  final String? profileTitle;

  const ImportResponse({
    required this.result,
    required this.configs,
    required this.error,
    this.dnsServers = const [],
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireTimestamp,
    this.subscriptionUrl,
    this.description = const [],
    this.profileTitle,
  });
}

class ImportService {
  /// Импорт из буфера обмена
  static Future<ImportResponse> importFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        return const ImportResponse(
          result: ImportResult.noConfig,
          configs: [],
          error: 'Буфер обмена пуст',
        );
      }
      return importFromText(text);
    } catch (e) {
      return ImportResponse(
        result: ImportResult.error,
        configs: const [],
        error: e.toString(),
      );
    }
  }

  /// Импорт из строки URI (из QR-кода или ввода вручную)
  static Future<ImportResponse> importFromUri(String uri) async {
    if (uri.trim().isEmpty) {
      return const ImportResponse(
        result: ImportResult.noConfig,
        configs: [],
        error: 'Пустая строка',
      );
    }
    return _parseUris(_normalizeImportText(uri));
  }

  /// Импорт из произвольного текста: URI, URL подписки или deep link.
  static Future<ImportResponse> importFromText(String text) async {
    final normalized = _normalizeImportText(text);
    if (normalized.isEmpty) {
      return const ImportResponse(
        result: ImportResult.noConfig,
        configs: [],
        error: 'Пустая строка',
      );
    }

    if (_isInsecureSubscriptionUrl(normalized)) {
      return const ImportResponse(
        result: ImportResult.error,
        configs: [],
        error: 'Для подписок поддерживаются только HTTPS-ссылки.',
      );
    }

    final subscriptionUrl = _extractSubscriptionUrl(normalized);
    if (subscriptionUrl != null) {
      return importFromSubscriptionUrl(subscriptionUrl);
    }

    return _parseUris(normalized);
  }

  /// Импорт по ссылке подписки
  static Future<ImportResponse> importFromSubscriptionUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (!_isSecureSubscriptionUri(uri)) {
        return const ImportResponse(
          result: ImportResult.error,
          configs: [],
          error: 'Для подписок поддерживаются только HTTPS-ссылки.',
        );
      }
      final device = await DeviceService.getDeviceInfo();
      final headers = device.subscriptionHeaders;

      final primaryFetch =
          await _fetchSubscriptionResponse(uri, headers: headers);
      if (primaryFetch.error != null) {
        return ImportResponse(
          result: ImportResult.error,
          configs: const [],
          error: primaryFetch.error,
        );
      }
      if (primaryFetch.response == null) {
        return const ImportResponse(
          result: ImportResult.error,
          configs: [],
          error: 'Не удалось получить ответ подписки',
        );
      }

      var activeUri = uri;
      var activeResponse = primaryFetch.response!;
      var body = activeResponse.body;
      var configs = ConfigParser.parseSubscription(body);

      if (!_containsJsonConfig(configs)) {
        final jsonUri = _buildJsonSubscriptionUri(uri);
        if (jsonUri != null) {
          final jsonFetch = await _fetchSubscriptionResponse(
            jsonUri,
            headers: headers,
          );
          final jsonResponse = jsonFetch.response;
          if (jsonFetch.error == null &&
              jsonResponse != null &&
              jsonResponse.statusCode == 200 &&
              jsonResponse.body.trim().isNotEmpty) {
            final jsonConfigs =
                ConfigParser.parseSubscription(jsonResponse.body);
            if (_containsJsonConfig(jsonConfigs)) {
              activeUri = jsonUri;
              activeResponse = jsonResponse;
              body = jsonResponse.body;
              configs = jsonConfigs;
            }
          }
        }
      }

      if (activeResponse.statusCode != 200) {
        return ImportResponse(
          result: ImportResult.error,
          configs: const [],
          error: 'Ошибка сервера: ${activeResponse.statusCode}',
        );
      }

      if (body.trim().isEmpty) {
        return const ImportResponse(
          result: ImportResult.noConfig,
          configs: [],
          error: 'Пустой ответ от сервера',
        );
      }

      if (configs.isEmpty) {
        return const ImportResponse(
          result: ImportResult.noConfig,
          configs: [],
          error: 'Конфиги не найдены в ответе',
        );
      }

      final rejection = hwidRejection(activeResponse.headers, configs);
      if (rejection != null) {
        return ImportResponse(
          result: ImportResult.error,
          configs: const [],
          error: rejection,
        );
      }

      final dnsServers = _extractDnsServers(activeResponse.headers, body);

      // Парсим profile-title (название подписки)
      final profileTitleRaw =
          _headerValue(activeResponse.headers, 'profile-title');
      final profileTitle = profileTitleRaw != null
          ? _nonEmptyOrNull(_decodeHeaderValue(profileTitleRaw))
          : null;

      // Парсим announce (описание — многострочный текст)
      final announceRaw = _headerValue(activeResponse.headers, 'announce');
      final List<String> description = announceRaw != null
          ? _decodeHeaderValue(announceRaw)
              .split(RegExp(r'[\r\n]+'))
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList()
          : const [];

      // Парсим заголовок subscription-userinfo
      // Ищем заголовок в любом регистре и с любым разделителем
      final userInfo =
          _headerValue(activeResponse.headers, 'subscription-userinfo');
      int? upload, download, total, expire;
      if (userInfo != null) {
        // Поддерживаем разделители ; и ,
        final parts = userInfo.split(RegExp(r'[;,]'));
        for (final part in parts) {
          final eqIdx = part.indexOf('=');
          if (eqIdx < 0) continue;
          final key = part.substring(0, eqIdx).trim().toLowerCase();
          final rawVal = part.substring(eqIdx + 1).trim();
          // Поддерживаем int и float (берём целую часть)
          final val = int.tryParse(rawVal) ?? double.tryParse(rawVal)?.toInt();
          if (val == null) continue;
          if (key == 'upload') upload = val;
          if (key == 'download') download = val;
          if (key == 'total') total = val;
          if (key == 'expire') expire = val;
        }
      }

      // Remnawave: дата обновления подписки отдельным заголовком.
      // Используем как fallback для expire, если в subscription-userinfo нет expire.
      final refillRaw = _headerValue(
        activeResponse.headers,
        'subscription-refill-date',
      );
      if (expire == null && refillRaw != null) {
        expire = int.tryParse(refillRaw.trim());
      }

      return ImportResponse(
        result: ImportResult.success,
        configs: configs,
        error: null,
        uploadBytes: upload,
        downloadBytes: download,
        totalBytes: total,
        expireTimestamp: expire,
        subscriptionUrl: activeUri.toString(),
        dnsServers: dnsServers,
        description: description,
        profileTitle: profileTitle,
      );
    } on FormatException {
      return const ImportResponse(
        result: ImportResult.error,
        configs: [],
        error: 'Неверный формат URL',
      );
    } catch (e) {
      return ImportResponse(
        result: ImportResult.error,
        configs: const [],
        error: 'Не удалось подключиться: $e',
      );
    }
  }

  // ─── Internal ─────────────────────────────────────────────────────────────
  static ImportResponse _parseUris(String text) {
    final configs = ConfigParser.parseText(text);

    if (configs.isEmpty) {
      // A subscription that only serves retired protocols now parses to
      // nothing. Saying "no valid config" there would send the user hunting
      // for a typo that isn't the problem.
      if (_containsOnlyRetiredSchemes(text)) {
        return const ImportResponse(
          result: ImportResult.noConfig,
          configs: [],
          error: 'Приложение поддерживает только VLESS и JSON-конфиги. '
              'Ключи VMess, Trojan, Shadowsocks и Hysteria больше не работают.',
        );
      }

      return const ImportResponse(
        result: ImportResult.noConfig,
        configs: [],
        error: 'Не найден корректный конфиг VPN',
      );
    }

    return ImportResponse(
      result: ImportResult.success,
      configs: configs,
      error: null,
    );
  }

  /// Декодирует значение заголовка: если начинается с "base64:", декодирует
  static String _decodeHeaderValue(String value) {
    final trimmed = value.trim();
    if (trimmed.toLowerCase().startsWith('base64:')) {
      final encoded =
          trimmed.substring(7).trim().replaceAll('"', '').replaceAll("'", '');
      try {
        return utf8.decode(base64Decode(base64.normalize(encoded)));
      } catch (_) {
        try {
          return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
        } catch (_) {}
      }
    }
    return trimmed;
  }

  static String? _nonEmptyOrNull(String? value) {
    if (value == null) return null;
    final v = value.trim();
    return v.isEmpty ? null : v;
  }

  /// Безопасно читает заголовок независимо от регистра ключа.
  static String? _headerValue(Map<String, String> headers, String key) {
    final direct = headers[key];
    if (direct != null) return direct;
    final lowerKey = key.toLowerCase();
    return headers.entries
        .where((e) => e.key.toLowerCase() == lowerKey)
        .map((e) => e.value)
        .firstOrNull;
  }

  static List<String> _extractDnsServers(
    Map<String, String> headers,
    String body,
  ) {
    final seen = <String>{};
    final dnsServers = <String>[];

    void addValues(String? raw) {
      if (raw == null) return;
      final decoded = _decodeHeaderValue(raw);
      final normalized = decoded
          .replaceAll(RegExp(r'[\r\n]+'), ',')
          .replaceAll(';', ',')
          .trim();
      if (normalized.isEmpty) return;

      for (final token in normalized.split(',')) {
        final value = token.trim();
        if (value.isEmpty) continue;
        if (value.contains('://')) continue;
        if (seen.add(value)) {
          dnsServers.add(value);
        }
      }
    }

    for (final key in const ['dns', 'x-dns', 'profile-dns']) {
      addValues(_headerValue(headers, key));
    }

    String decodedBody = body.trim();
    try {
      decodedBody = utf8.decode(base64Decode(body.trim()));
    } catch (_) {}

    for (final line in decodedBody.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final match = RegExp(
        r'^(?:[#;\/]{0,2}\s*)?dns\s*[:=]\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (match != null) {
        addValues(match.group(1));
      }
    }

    return dnsServers;
  }

  /// Проверяет, является ли текст поддерживаемым URI
  static bool isValidVpnUri(String text) {
    final normalized = _normalizeImportText(text);
    if (normalized.isEmpty) return false;
    if (ConfigParser.parseText(normalized).isNotEmpty) {
      return true;
    }
    return normalized.toLowerCase().startsWith('vless://');
  }

  /// True when the text is a key the app used to accept but no longer does.
  ///
  /// Import treats this separately from plain garbage so the user is told the
  /// protocol was dropped, rather than left staring at "не удалось распознать".
  static bool isRetiredVpnUri(String text) {
    final normalized = _normalizeImportText(text);
    return normalized.isNotEmpty && ConfigParser.isRetiredScheme(normalized);
  }

  /// Whether every key in the blob uses a protocol the app has dropped.
  static bool _containsOnlyRetiredSchemes(String text) {
    var sawRetired = false;
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!ConfigParser.isRetiredScheme(trimmed)) return false;
      sawRetired = true;
    }
    return sawRetired;
  }

  /// Проверяет, можно ли импортировать текст из QR/буфера.
  static bool canImportText(String text) {
    final normalized = _normalizeImportText(text);
    return normalized.isNotEmpty &&
        (_extractSubscriptionUrl(normalized) != null ||
            isValidVpnUri(normalized));
  }

  static String _normalizeImportText(String text) {
    final trimmed = text.replaceAll('\uFEFF', '').trim();
    if (trimmed.isEmpty) {
      return '';
    }

    final deepLinkUrl = _extractDeepLinkUrl(trimmed);
    if (deepLinkUrl != null) {
      return deepLinkUrl;
    }

    final mebkmMatch = RegExp(
      r'^MEBKM:(?:TITLE:[^;]*;)?URL:([^;]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (mebkmMatch != null) {
      return mebkmMatch.group(1)?.trim() ?? trimmed;
    }

    final urlToMatch = RegExp(
      r'^URLTO:(?:[^:]*:)?(.+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (urlToMatch != null) {
      return urlToMatch.group(1)?.trim() ?? trimmed;
    }

    return trimmed;
  }

  static String? _extractSubscriptionUrl(String text) {
    if (text.startsWith('https://')) {
      return text;
    }
    return null;
  }

  static bool _isInsecureSubscriptionUrl(String text) {
    return text.startsWith('http://');
  }

  static bool _isSecureSubscriptionUri(Uri uri) {
    return uri.scheme.toLowerCase() == 'https';
  }

  static bool _containsJsonConfig(List<ServerConfig> configs) {
    return configs.any((config) => config.protocol.toLowerCase() == 'json');
  }

  /// Текст ошибки, если панель отклонила устройство, иначе `null`.
  ///
  /// Антишеринговые панели (Remnawave и аналоги) отвечают на такой запрос не
  /// ошибкой, а `200` с конфигом-заглушкой, у которого вместо адреса стоит
  /// `0.0.0.0`, а название — текст отказа. Без этой проверки заглушка
  /// импортируется как обычный сервер.
  @visibleForTesting
  static String? hwidRejection(
    Map<String, String> headers,
    List<ServerConfig> configs,
  ) {
    final deviceLimit = _isTrueHeader(headers, 'x-hwid-limit-reached') ||
        _isTrueHeader(headers, 'x-hwid-device-limit-reached');
    if (deviceLimit) {
      return 'Сервер подписки отклонил это устройство: достигнут лимит '
          'устройств. Удалите лишнее устройство в личном кабинете и '
          'повторите.';
    }

    final notSupported = _isTrueHeader(headers, 'x-hwid-not-supported');
    if (!notSupported && !_isOnlyPlaceholders(configs)) {
      return null;
    }

    return 'Сервер подписки не принял идентификатор устройства (HWID) и '
        'вернул заглушку вместо серверов. Проверьте подписку в личном '
        'кабинете или обратитесь в поддержку.';
  }

  static bool _isTrueHeader(Map<String, String> headers, String key) {
    final value = _headerValue(headers, key)?.trim().toLowerCase();
    return value == 'true' || value == '1';
  }

  static bool _isOnlyPlaceholders(List<ServerConfig> configs) {
    if (configs.isEmpty) return false;
    return configs.every(_isPlaceholderConfig);
  }

  static bool _isPlaceholderConfig(ServerConfig config) {
    // 127.0.0.1 намеренно не в списке: локальный адрес встречается в рабочих
    // самодельных конфигах, а 0.0.0.0 реальным адресом сервера быть не может.
    const deadHosts = {'0.0.0.0', '::'};
    final host = config.host.trim().toLowerCase();
    if (host.isEmpty || deadHosts.contains(host)) return true;

    final uuid = config.uuid.trim();
    return uuid.isNotEmpty &&
        uuid.replaceAll('-', '').replaceAll('0', '').isEmpty;
  }

  static Uri? _buildJsonSubscriptionUri(Uri uri) {
    final segments =
        uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    if (segments.last.toLowerCase() == 'json') return null;

    return uri.replace(
      pathSegments: [...segments, 'json'],
    );
  }

  static Future<({http.Response? response, String? error})>
      _fetchSubscriptionResponse(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    try {
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      return (response: response, error: null);
    } catch (e) {
      return (response: null, error: 'Не удалось подключиться: $e');
    }
  }

  static String? _extractDeepLinkUrl(String raw) {
    const scheme = 'chrnet://add/';
    if (raw.toLowerCase().startsWith(scheme)) {
      final payload = raw.substring(scheme.length).trim();
      if (payload.isNotEmpty) {
        return Uri.decodeFull(payload).trim();
      }
    }
    return null;
  }
}
