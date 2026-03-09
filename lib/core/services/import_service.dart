import 'dart:convert';
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
      // Если это ссылка на подписку — скачиваем
      if (text.startsWith('http://') || text.startsWith('https://')) {
        return importFromSubscriptionUrl(text);
      }
      return _parseUris(text);
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
    return _parseUris(uri.trim());
  }

  /// Импорт по ссылке подписки
  static Future<ImportResponse> importFromSubscriptionUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      final device = await DeviceService.getDeviceInfo();
      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'ChrNet/1.0 (Android)',
          if (device.deviceId.isNotEmpty) 'x-hwid': device.deviceId,
          'x-device-os': 'Android',
          if (device.osVersion.isNotEmpty) 'x-ver-os': device.osVersion,
          if (device.model.isNotEmpty) 'x-device-model': device.model,
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        return ImportResponse(
          result: ImportResult.error,
          configs: const [],
          error: 'Ошибка сервера: ${response.statusCode}',
        );
      }

      final body = response.body;
      if (body.trim().isEmpty) {
        return const ImportResponse(
          result: ImportResult.noConfig,
          configs: [],
          error: 'Пустой ответ от сервера',
        );
      }

      final configs = ConfigParser.parseSubscription(body);
      if (configs.isEmpty) {
        return const ImportResponse(
          result: ImportResult.noConfig,
          configs: [],
          error: 'Конфиги не найдены в ответе',
        );
      }

      // Парсим profile-title (название подписки)
      final profileTitleRaw = _headerValue(response.headers, 'profile-title');
      final profileTitle = profileTitleRaw != null
          ? _nonEmptyOrNull(_decodeHeaderValue(profileTitleRaw))
          : null;

      // Парсим announce (описание — многострочный текст)
      final announceRaw = _headerValue(response.headers, 'announce');
      final List<String> description = announceRaw != null
          ? _decodeHeaderValue(announceRaw)
              .split(RegExp(r'[\r\n]+'))
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList()
          : const [];

      // Парсим заголовок subscription-userinfo
      // Ищем заголовок в любом регистре и с любым разделителем
      final userInfo = _headerValue(response.headers, 'subscription-userinfo');
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
      final refillRaw =
          _headerValue(response.headers, 'subscription-refill-date');
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
        subscriptionUrl: url,
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
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final configs = <ServerConfig>[];
    for (int i = 0; i < lines.length; i++) {
      final c = ConfigParser.parse(lines[i], subscriptionOrder: i);
      if (c != null) configs.add(c);
    }

    if (configs.isEmpty) {
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

  /// Проверяет, является ли текст поддерживаемым URI
  static bool isValidVpnUri(String text) {
    return text.startsWith('vless://') ||
        text.startsWith('vmess://') ||
        text.startsWith('trojan://') ||
        text.startsWith('ss://');
  }
}
