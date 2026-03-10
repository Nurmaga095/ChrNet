import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/server_config.dart';
import '../models/subscription.dart';

class StorageService {
  static const String _serversBox = 'servers_v2';
  static const String _subsBox = 'subscriptions_v2';
  static const String _settingsBox = 'settings';
  static const int _settingsSchemaVersion = 101;

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

    // For subscription servers, preserve provider-defined order from feed.
    list.sort((a, b) {
      final sameSub =
          a.subscriptionId != null && a.subscriptionId == b.subscriptionId;
      if (sameSub &&
          a.subscriptionOrder != null &&
          b.subscriptionOrder != null) {
        final byOrder = a.subscriptionOrder!.compareTo(b.subscriptionOrder!);
        if (byOrder != 0) return byOrder;
      }

      final byAddedAt = a.addedAt.compareTo(b.addedAt);
      if (byAddedAt != 0) return byAddedAt;
      return a.id.compareTo(b.id);
    });
    return list;
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

  static bool getAutoStart() => (_settingsB.get('autoStart') as bool?) ?? false;

  static Future<void> setAutoStart(bool value) async {
    await _settingsB.put('autoStart', value);
  }

  static bool getBypassLan() => (_settingsB.get('bypassLan') as bool?) ?? true;

  static Future<void> setBypassLan(bool value) async {
    await _settingsB.put('bypassLan', value);
  }

  static bool getRuRouting() => (_settingsB.get('ruRouting') as bool?) ?? false;

  static Future<void> setRuRouting(bool value) async {
    await _settingsB.put('ruRouting', value);
  }

  static String getWindowsVpnMode() =>
      (_settingsB.get('windowsVpnMode') as String?) ?? 'tunnel';

  static Future<void> setWindowsVpnMode(String mode) async {
    await _settingsB.put('windowsVpnMode', mode);
  }

  static int getSubscriptionAutoUpdateHours() =>
      (_settingsB.get('subscriptionAutoUpdateHours') as int?) ?? 0;

  static Future<void> setSubscriptionAutoUpdateHours(int hours) async {
    await _settingsB.put(
      'subscriptionAutoUpdateHours',
      hours < 0 ? 0 : hours,
    );
  }

  static ThemeMode getThemeMode() {
    final val = _settingsB.get('themeMode') as String?;
    switch (val) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    final val = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.dark
            ? 'dark'
            : 'system';
    await _settingsB.put('themeMode', val);
  }
}
