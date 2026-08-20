import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/server_config.dart';
import '../models/subscription.dart';

class StorageService {
  static const String _serversBox = 'servers_v2';
  static const String _subsBox = 'subscriptions_v2';
  static const String _settingsBox = 'settings';
  static const int _settingsSchemaVersion = 107;
  static const int minSubscriptionAutoUpdateHours = 1;
  static const int maxSubscriptionAutoUpdateHours = 24;
  static const int defaultSubscriptionAutoUpdateHours = 6;
  static const String pingMethodTcp = 'tcp';
  static const String pingMethodIcmp = 'icmp';
  static const String pingMethodProxyGet = 'proxy_get';
  static const String pingMethodProxyHead = 'proxy_head';
  static const String defaultPingMethod = pingMethodProxyGet;
  static const String defaultPingTestUrl =
      'https://www.gstatic.com/generate_204';
  static const String _privacyDisclosureVersionKey =
      'privacyDisclosureAcceptedVersion';
  static const String _fallbackHwidKey = 'fallbackHwid';

  static late Box<String> _serversB;
  static late Box<String> _subsB;
  static late Box _settingsB;

  static Future<void> init() async {
    await Hive.initFlutter();
    _serversB = await Hive.openBox<String>(_serversBox);
    _subsB = await Hive.openBox<String>(_subsBox);
    _settingsB = await Hive.openBox(_settingsBox);
    await _runMigrations();
  }

  static Future<void> _runMigrations() async {
    final storedVersion =
        (_settingsB.get('settingsSchemaVersion') as int?) ?? 0;

    if (storedVersion < 101) {
      final currentWindowsMode = _settingsB.get('windowsVpnMode') as String?;
      if (currentWindowsMode == null || currentWindowsMode == 'system_proxy') {
        await _settingsB.put('windowsVpnMode', 'tunnel');
      }
      await _settingsB.delete('dns');
    }

    if (storedVersion < 102) {
      await _settingsB.delete('ruRouting');
    }

    if (storedVersion < 103 && !_settingsB.containsKey('ruRouting')) {
      await _settingsB.put('ruRouting', true);
    }

    if (storedVersion < 104) {
      final autoUpdateHours =
          _settingsB.get('subscriptionAutoUpdateHours') as int?;
      if (autoUpdateHours == null || autoUpdateHours <= 0) {
        await _settingsB.put(
          'subscriptionAutoUpdateHours',
          defaultSubscriptionAutoUpdateHours,
        );
      }
    }

    if (storedVersion < 105) {
      final autoUpdateHours =
          _settingsB.get('subscriptionAutoUpdateHours') as int?;
      if (autoUpdateHours != null &&
          autoUpdateHours > maxSubscriptionAutoUpdateHours) {
        await _settingsB.put(
          'subscriptionAutoUpdateHours',
          maxSubscriptionAutoUpdateHours,
        );
      }
    }

    if (storedVersion < 106) {
      final pingMethod = _settingsB.get('pingMethod') as String?;
      if (!_isValidPingMethod(pingMethod)) {
        await _settingsB.put('pingMethod', defaultPingMethod);
      }
    }

    if (storedVersion < 107) {
      final pingTestUrl = _settingsB.get('pingTestUrl') as String?;
      if (pingTestUrl == null || pingTestUrl.trim().isEmpty) {
        await _settingsB.put('pingTestUrl', defaultPingTestUrl);
      }
    }

    if (storedVersion != _settingsSchemaVersion) {
      await _settingsB.put('settingsSchemaVersion', _settingsSchemaVersion);
    }
  }

  // ─── Servers ──────────────────────────────────────────────────────────────

  static List<ServerConfig> getServers() {
    final list = _serversB.values
        .map(
            (s) => ServerConfig.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();

    final indexed = list.indexed.toList();
    indexed.sort((left, right) {
      final a = left.$2;
      final b = right.$2;
      final sameSubscription =
          a.subscriptionId != null && a.subscriptionId == b.subscriptionId;

      if (sameSubscription &&
          a.subscriptionOrder != null &&
          b.subscriptionOrder != null) {
        final orderCompare =
            a.subscriptionOrder!.compareTo(b.subscriptionOrder!);
        if (orderCompare != 0) return orderCompare;
      }

      return left.$1.compareTo(right.$1);
    });

    return indexed.map((entry) => entry.$2).toList();
  }

  static Future<void> deleteServer(String id) async {
    await _serversB.delete(id);
  }

  static bool serverExists(String rawUri) {
    return getServers().any((s) => s.rawUri == rawUri);
  }

  static Future<void> saveServers(List<ServerConfig> configs) async {
    for (final c in configs) {
      await _serversB.put(c.id, jsonEncode(c.toJson()));
    }
  }

  // ─── Subscriptions ────────────────────────────────────────────────────────

  static List<Subscription> getSubscriptions() {
    return _subsB.values
        .map(
            (s) => Subscription.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> saveSubscription(Subscription sub) async {
    await _subsB.put(sub.id, jsonEncode(sub.toJson()));
  }

  static Future<void> deleteSubscription(String id) async {
    await _subsB.delete(id);
    final toDelete = getServers()
        .where((s) => s.subscriptionId == id)
        .map((s) => s.id)
        .toList();
    for (final sid in toDelete) {
      await _serversB.delete(sid);
    }
  }

  // ─── Settings ─────────────────────────────────────────────────────────────

  static String? getSelectedServerId() =>
      _settingsB.get('selectedServerId') as String?;

  static Future<void> setSelectedServerId(String? id) async {
    await _settingsB.put('selectedServerId', id);
  }

  static bool getBypassLan() => (_settingsB.get('bypassLan') as bool?) ?? true;

  static Future<void> setBypassLan(bool value) async {
    await _settingsB.put('bypassLan', value);
  }

  static bool getRuRouting() => (_settingsB.get('ruRouting') as bool?) ?? true;

  static Future<void> setRuRouting(bool value) async {
    await _settingsB.put('ruRouting', value);
  }

  /// One of `system`, `light`, `dark`. Defaults to following the OS setting.
  static String getThemeMode() {
    final stored = _settingsB.get('themeMode') as String?;
    return const {'system', 'light', 'dark'}.contains(stored)
        ? stored!
        : 'system';
  }

  static Future<void> setThemeMode(String mode) async {
    await _settingsB.put('themeMode', mode);
  }

  /// `null` means "follow the platform default" — see [AppPerf.liteEffects].
  /// Only an explicit user choice is stored, so devices keep tracking the
  /// default if we ever change it.
  static bool? getLiteEffects() => _settingsB.get('liteEffects') as bool?;

  static Future<void> setLiteEffects(bool? value) async {
    if (value == null) {
      await _settingsB.delete('liteEffects');
    } else {
      await _settingsB.put('liteEffects', value);
    }
  }

  static String getWindowsVpnMode() =>
      (_settingsB.get('windowsVpnMode') as String?) ?? 'tunnel';

  static Future<void> setWindowsVpnMode(String mode) async {
    await _settingsB.put('windowsVpnMode', mode);
  }

  static int getSubscriptionAutoUpdateHours() {
    final hours = _settingsB.get('subscriptionAutoUpdateHours') as int?;
    if (hours == null || hours <= 0) {
      return defaultSubscriptionAutoUpdateHours;
    }
    if (hours > maxSubscriptionAutoUpdateHours) {
      return maxSubscriptionAutoUpdateHours;
    }
    return hours;
  }

  static Future<void> setSubscriptionAutoUpdateHours(int hours) async {
    final normalizedHours = hours <= 0
        ? defaultSubscriptionAutoUpdateHours
        : hours > maxSubscriptionAutoUpdateHours
            ? maxSubscriptionAutoUpdateHours
            : hours;
    await _settingsB.put(
      'subscriptionAutoUpdateHours',
      normalizedHours,
    );
  }

  static String getPingMethod() {
    final method = _settingsB.get('pingMethod') as String?;
    if (_isValidPingMethod(method)) {
      return method!;
    }
    return defaultPingMethod;
  }

  static Future<void> setPingMethod(String method) async {
    final normalizedMethod =
        _isValidPingMethod(method) ? method : defaultPingMethod;
    await _settingsB.put('pingMethod', normalizedMethod);
  }

  static String getPingTestUrl() {
    final url = (_settingsB.get('pingTestUrl') as String?)?.trim();
    return url == null || url.isEmpty ? defaultPingTestUrl : url;
  }

  static Future<void> setPingTestUrl(String url) async {
    final normalizedUrl = url.trim().isEmpty ? defaultPingTestUrl : url.trim();
    await _settingsB.put('pingTestUrl', normalizedUrl);
  }

  static bool _isValidPingMethod(String? method) {
    return method == pingMethodTcp ||
        method == pingMethodIcmp ||
        method == pingMethodProxyGet ||
        method == pingMethodProxyHead;
  }

  static String? getPrivacyDisclosureAcceptedVersion() =>
      _settingsB.get(_privacyDisclosureVersionKey) as String?;

  static Future<void> setPrivacyDisclosureAcceptedVersion(
    String version,
  ) async {
    await _settingsB.put(_privacyDisclosureVersionKey, version);
  }

  /// HWID, выданный устройству локально.
  ///
  /// Используется только когда платформа не смогла сообщить свой собственный
  /// идентификатор: подписочные серверы отклоняют запрос без HWID, поэтому
  /// пустым его отправлять нельзя.
  static String? getFallbackHwid() {
    final hwid = (_settingsB.get(_fallbackHwidKey) as String?)?.trim();
    return hwid == null || hwid.isEmpty ? null : hwid;
  }

  static Future<void> setFallbackHwid(String hwid) async {
    await _settingsB.put(_fallbackHwidKey, hwid.trim());
  }
}
