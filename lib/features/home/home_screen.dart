import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/models/server_config.dart';
import '../../core/models/subscription.dart';
import '../../core/models/vpn_stats.dart';
import '../../core/services/deep_link_service.dart';
import '../../core/services/import_service.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/vpn_provider.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/power_button.dart';
import '../../ui/widgets/stats_card.dart';
import '../servers/add_server_sheet.dart' show QrScanScreen;
import '../settings/settings_screen.dart';
import '../../ui/widgets/glass_card.dart';

enum _TopNoticeType { info, success, error }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const double _heroScale = 0.7;
  List<ServerConfig> _servers = [];
  List<Subscription> _subscriptions = [];
  final Set<String> _refreshing = {};
  final Set<String> _checkingPing = {};
  final Map<String, int?> _tcpPingByServerId = {};
  OverlayEntry? _topNoticeEntry;
  Timer? _topNoticeTimer;
  StreamSubscription<String>? _deepLinkSub;
  bool _deepLinkProcessing = false;

  double _s(double value) => value * _heroScale;

  @override
  void initState() {
    super.initState();
    _loadAll();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkDeepLink());
    _deepLinkSub = DeepLinkService.urlStream.listen((url) {
      // Поглощаем pendingUrl чтобы _checkDeepLink не обработал его повторно
      DeepLinkService.consumePendingUrl();
      _handleDeepLinkUrl(url);
    });
  }

  Future<void> _checkDeepLink() async {
    final url = DeepLinkService.consumePendingUrl();
    if (url == null) return;
    await _handleDeepLinkUrl(url);
  }

  Future<void> _handleDeepLinkUrl(String url) async {
    if (!mounted || _deepLinkProcessing) return;
    _deepLinkProcessing = true;
    try {
      final messenger = ScaffoldMessenger.of(context);
      _showTopNotice('Загрузка подписки…', _TopNoticeType.info);
      final res = await ImportService.importFromSubscriptionUrl(url);
      if (!mounted) return;
      await _handleImportResult(messenger, res);
    } finally {
      _deepLinkProcessing = false;
    }
  }

  @override
  void dispose() {
    _deepLinkSub?.cancel();
    _topNoticeTimer?.cancel();
    _topNoticeEntry?.remove();
    _topNoticeEntry = null;
    super.dispose();
  }

  void _loadAll() {
    setState(() {
      _servers = StorageService.getServers();
      _subscriptions = StorageService.getSubscriptions();
      _syncPingCache();
    });
  }

  void _loadServers() => _loadAll();

  void _syncPingCache() {
    final next = <String, int?>{};
    for (final server in _servers) {
      next[server.id] = _tcpPingByServerId[server.id];
    }
    _tcpPingByServerId
      ..clear()
      ..addAll(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Consumer<VpnProvider>(
      builder: (context, vpn, _) {
        final supportsQrScan =
            Theme.of(context).platform == TargetPlatform.android ||
                Theme.of(context).platform == TargetPlatform.iOS;
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _WatermarkPainter(
                      AppColors.of(context).textSecondary.withValues(alpha: 0.13),
                    ),
                  ),
                ),
              ),
              // ── Floating action buttons (top-right) ──────────────────────
              Positioned(
                top: 10,
                right: 14,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── + Добавить ──────────────────────────────────────────
                    PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      color: c.cardBackground,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: c.borderColor),
                      ),
                      offset: const Offset(0, 52),
                      onSelected: (value) async {
                        if (value == 'clipboard') {
                          final messenger = ScaffoldMessenger.of(context);
                          final result =
                              await ImportService.importFromClipboard();
                          _handleImportResult(messenger, result);
                        } else if (value == 'qr' && supportsQrScan) {
                          if (!context.mounted) return;
                          final messenger = ScaffoldMessenger.of(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => QrScanScreen(
                                onScanned: (uri) async {
                                  final result =
                                      await ImportService.importFromUri(uri);
                                  _handleImportResult(messenger, result);
                                },
                              ),
                            ),
                          );
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem<String>(
                          value: 'clipboard',
                          child: Row(
                            children: [
                              const Icon(Icons.content_paste_rounded,
                                  color: AppColors.accent, size: 20),
                              const SizedBox(width: 12),
                              Text('Из буфера обмена',
                                  style: TextStyle(color: c.textPrimary)),
                            ],
                          ),
                        ),
                        if (supportsQrScan)
                          PopupMenuItem<String>(
                            value: 'qr',
                            child: Row(
                              children: [
                                const Icon(Icons.qr_code_scanner_rounded,
                                    color: AppColors.accent, size: 20),
                                const SizedBox(width: 12),
                                Text('Сканировать QR-код',
                                    style: TextStyle(color: c.textPrimary)),
                              ],
                            ),
                          ),
                      ],
                      child: const _AppBarButton(
                        icon: Icons.add_rounded,
                        iconSize: 26,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── Личный кабинет ──────────────────────────────────────
                    Tooltip(
                      message: 'Личный кабинет',
                      child: GestureDetector(
                        onTap: _openSubscriptionSite,
                        child: const _AppBarButton(
                          icon: Icons.manage_accounts_rounded,
                          iconSize: 22,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── Настройки ───────────────────────────────────────────
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SettingsScreen()),
                      ),
                      child: const _AppBarButton(
                        icon: Icons.settings_rounded,
                        iconSize: 22,
                      ),
                    ),
                  ],
                ),
              ),
              ListView(
            padding: const EdgeInsets.only(left: 20, right: 20, bottom: 32),
            children: [
              SizedBox(height: _s(16)),

              // ── Status / Timer ─────────────────────────────────────────────
              _buildStatusOrTimer(vpn, context, scale: _heroScale),
              SizedBox(height: _s(10)),

              // ── Power Button ───────────────────────────────────────────────
              Center(
                child: PowerButton(
                  status: vpn.status,
                  scale: _heroScale,
                  onTap: () {
                    if (vpn.selectedServer == null && _servers.isNotEmpty) {
                      vpn.selectServer(_servers.first);
                    }
                    if (_servers.isNotEmpty) {
                      vpn.toggleConnection();
                    }
                  },
                ),
              ),
              // ── Fixed-height area: stats + error (prevents list from jumping) ──
              SizedBox(
                height: _s(52),
                child: Center(
                  child: vpn.errorMessage != null
                      ? Text(
                          vpn.errorMessage!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AppColors.error, fontSize: _s(12)),
                        )
                      : vpn.status == VpnStatus.connected
                          ? StatsCard(stats: vpn.stats)
                          : null,
                ),
              ),

              SizedBox(height: _s(10)),
              ..._buildSubscriptionSections(context, vpn),

              if (_subscriptions.isEmpty) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final result = await ImportService.importFromClipboard();
                      _handleImportResult(messenger, result);
                    },
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: const Text('Из буфера'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      side: const BorderSide(color: AppColors.accent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ], // if _subscriptions.isEmpty
              const SizedBox(height: 24),
            ],
          ), // ListView
            ],
          ), // Stack
        );
      },
    );
  }

  Widget _buildStatusOrTimer(VpnProvider vpn, BuildContext context,
      {double scale = 1}) {
    final c = AppColors.of(context);
    switch (vpn.status) {
      case VpnStatus.connected:
        final duration = vpn.stats.connectedDuration;
        final h = duration.inHours.toString().padLeft(2, '0');
        final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
        final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
        return Text(
          '$h : $m : $s',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 17 * scale,
            fontWeight: FontWeight.w300,
            letterSpacing: 6 * scale,
          ),
        );
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        return Text(
          vpn.status.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.accent,
            fontSize: 15 * scale,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.5 * scale,
          ),
        );
      case VpnStatus.disconnected:
      case VpnStatus.error:
        return Text(
          'Не подключено',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 17 * scale,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
        );
    }
  }

  List<String> _locationInfoLines(Subscription? activeSub) {
    if (activeSub == null) return const [];
    return activeSub.description
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  List<Widget> _buildSubscriptionSections(
      BuildContext context, VpnProvider vpn) {
    final c = AppColors.of(context);
    if (_servers.isEmpty) {
      return [
        GlassCard(
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _buildEmpty(context),
          ),
        ),
      ];
    }

    final bySubId = <String, List<ServerConfig>>{};
    final orphanServers = <ServerConfig>[];
    final subIds = _subscriptions.map((s) => s.id).toSet();

    for (final server in _servers) {
      final sid = server.subscriptionId;
      if (sid == null || !subIds.contains(sid)) {
        orphanServers.add(server);
        continue;
      }
      bySubId.putIfAbsent(sid, () => <ServerConfig>[]).add(server);
    }

    final sections = <Widget>[];

    for (final sub in _subscriptions) {
      final subServers = bySubId[sub.id] ?? const <ServerConfig>[];
      final sectionChildren = <Widget>[];

      sectionChildren.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: _SubCard(
            subscription: sub,
            isRefreshing: _refreshing.contains(sub.id),
            isCheckingPing: _checkingPing.contains(sub.id),
            onRefresh: () => _refreshSub(sub),
            onCheckPing: () => _checkTcpPingForSubscription(sub),
            onDelete: () => _deleteSub(sub),
          ),
        ),
      );

      final infoLines = _locationInfoLines(sub);
      if (infoLines.isNotEmpty) {
        sectionChildren.add(Divider(height: 1, color: c.borderColor));
        sectionChildren.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: _buildLocationsInfo(context, infoLines),
          ),
        );
      }

      if (subServers.isNotEmpty) {
        sectionChildren.add(Divider(height: 1, color: c.borderColor));
        sectionChildren.addAll(_buildServerRows(vpn, subServers));
      }

      sections.add(
        GlassCard(
          borderRadius: BorderRadius.circular(20),
          child: Column(children: sectionChildren),
        ),
      );
    }

    if (orphanServers.isNotEmpty) {
      sections.add(
        GlassCard(
          borderRadius: BorderRadius.circular(20),
          child: Column(children: _buildServerRows(vpn, orphanServers)),
        ),
      );
    }

    if (sections.isEmpty) {
      sections.add(
        GlassCard(
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _buildEmpty(context),
          ),
        ),
      );
    }

    return sections.asMap().entries.expand((entry) {
      final out = <Widget>[];
      if (entry.key > 0) out.add(const SizedBox(height: 12));
      out.add(entry.value);
      return out;
    }).toList();
  }

  List<Widget> _buildServerRows(VpnProvider vpn, List<ServerConfig> servers) {
    final c = AppColors.of(context);
    final selectedId = vpn.selectedServer?.id;
    final effectiveSelectedId =
        selectedId ?? (_servers.isNotEmpty ? _servers.first.id : null);

    return servers.asMap().entries.map((entry) {
      final index = entry.key;
      final server = entry.value;
      return Column(
        children: [
          if (index > 0) Divider(height: 1, color: c.borderColor),
          Dismissible(
            key: Key('server_${server.id}'),
            direction: DismissDirection.endToStart,
            confirmDismiss: (_) => _confirmDeleteServer(server),
            onDismissed: (_) async {
              await StorageService.deleteServer(server.id);
              _loadServers();
            },
            background: Container(
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 18),
              child: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.error, size: 22),
            ),
            child: _ServerRow(
              server: server,
              pingMs: _tcpPingByServerId[server.id],
              isSelected: effectiveSelectedId == server.id,
              onTap: () {
                vpn.selectServer(server);
                setState(() {});
              },
            ),
          ),
        ],
      );
    }).toList();
  }

  Widget _buildLocationsInfo(BuildContext context, List<String> lines) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines
          .asMap()
          .entries
          .expand((entry) => [
                Text(
                  entry.value,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: entry.value.toLowerCase().contains('осталось')
                        ? 13
                        : 11.5,
                    height: 1.2,
                    fontWeight: entry.value.toLowerCase().contains('осталось')
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
                if (entry.key != lines.length - 1) const SizedBox(height: 3),
              ])
          .toList(),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          Icon(Icons.public_outlined, size: 48, color: c.textDisabled),
          const SizedBox(height: 12),
          Text(
            'Нет конфигураций',
            style: TextStyle(color: c.textSecondary, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            'Нажмите + чтобы добавить VPN-сервер',
            style: TextStyle(color: c.textDisabled, fontSize: 12),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _openSubscriptionSite,
            icon: const Icon(Icons.shopping_cart_outlined, size: 18),
            label: const Text(
              'Купить подписку',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accent,
              side: const BorderSide(color: AppColors.accent),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSubscriptionSite() async {
    final uri = Uri.parse('https://miniapp.chrnet.ru');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _showSnack(
        ScaffoldMessenger.of(context),
        'Не удалось открыть сайт',
      );
    }
  }

  Future<void> _handleImportResult(
    ScaffoldMessengerState messenger,
    ImportResponse res,
  ) async {
    if (res.result == ImportResult.success && res.configs.isNotEmpty) {
      // Если это была подписка — создаём/обновляем объект Subscription
      String? subId;
      if (res.subscriptionUrl != null) {
        final existing = StorageService.getSubscriptions()
            .where((s) => s.url == res.subscriptionUrl)
            .firstOrNull;
        if (existing != null) {
          existing.lastUpdated = DateTime.now();
          existing.serverCount = res.configs.length;
          if (res.profileTitle != null) existing.name = res.profileTitle!;
          if (res.uploadBytes != null) existing.uploadBytes = res.uploadBytes;
          if (res.downloadBytes != null) {
            existing.downloadBytes = res.downloadBytes;
          }
          if (res.totalBytes != null) existing.totalBytes = res.totalBytes;
          if (res.expireTimestamp != null) {
            existing.expireTimestamp = res.expireTimestamp;
          }
          existing.description = res.description;
          await StorageService.saveSubscription(existing);
          subId = existing.id;
          // Удаляем старые серверы подписки перед обновлением
          final oldServers = StorageService.getServers()
              .where((s) => s.subscriptionId == existing.id)
              .toList();
          for (final s in oldServers) {
            await StorageService.deleteServer(s.id);
          }
        } else {
          final sub = Subscription(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: res.profileTitle ?? 'Подписка',
            url: res.subscriptionUrl!,
            lastUpdated: DateTime.now(),
            serverCount: res.configs.length,
            uploadBytes: res.uploadBytes,
            downloadBytes: res.downloadBytes,
            totalBytes: res.totalBytes,
            expireTimestamp: res.expireTimestamp,
            description: res.description,
          );
          await StorageService.saveSubscription(sub);
          subId = sub.id;
        }
      }

      // Для одиночных конфигов (не подписок) фильтруем дубли
      final newConfigs = subId != null
          ? res.configs
          : res.configs
              .where((c) => !StorageService.serverExists(c.rawUri))
              .toList();
      if (newConfigs.isEmpty) {
        _loadAll();
        _showSnack(messenger, 'Серверы уже добавлены', isError: false);
        return;
      }
      // Привязываем серверы к подписке
      if (subId != null) {
        for (final c in newConfigs) {
          c.subscriptionId = subId;
        }
      }
      await StorageService.saveServers(newConfigs);
      _loadServers();
      if (subId != null && mounted) {
        context.read<VpnProvider>().selectServer(newConfigs.first);
      }
      _showSnack(
        messenger,
        newConfigs.length == 1
            ? 'Сервер добавлен: ${newConfigs.first.displayName}'
            : 'Добавлено серверов: ${newConfigs.length}',
        isError: false,
      );
    } else {
      _showSnack(messenger, res.error ?? 'Ошибка импорта');
    }
  }

  void _showSnack(
    ScaffoldMessengerState messenger,
    String message, {
    bool isError = true,
    _TopNoticeType? type,
  }) {
    final resolvedType =
        type ?? (isError ? _TopNoticeType.error : _TopNoticeType.success);
    messenger.hideCurrentMaterialBanner();
    messenger.hideCurrentSnackBar();
    _showTopNotice(message, resolvedType);
  }

  void _showTopNotice(String message, _TopNoticeType type) {
    if (!mounted) return;
    _topNoticeTimer?.cancel();
    _topNoticeEntry?.remove();
    _topNoticeEntry = null;

    final overlay = Overlay.of(context, rootOverlay: true);

    final iconData = switch (type) {
      _TopNoticeType.info => Icons.info_outline_rounded,
      _TopNoticeType.success => Icons.check_rounded,
      _TopNoticeType.error => Icons.close_rounded,
    };
    final iconColor = switch (type) {
      _TopNoticeType.info => const Color(0xFFF59B2A),
      _TopNoticeType.success => AppColors.connected,
      _TopNoticeType.error => AppColors.error,
    };

    final key = GlobalKey<_TopNoticeHostState>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final safeTop = MediaQuery.of(ctx).padding.top + 8;
        final c = AppColors.of(ctx);
        return Positioned(
          top: safeTop,
          left: 16,
          right: 16,
          child: _TopNoticeHost(
            key: key,
            child: IgnorePointer(
              child: Material(
                color: Colors.transparent,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: IntrinsicWidth(
                    child: GlassCard(
                      borderRadius: BorderRadius.circular(14),
                      blur: 24,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: iconColor,
                                shape: BoxShape.circle,
                              ),
                              child:
                                  Icon(iconData, color: Colors.white, size: 13),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              message,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);
    _topNoticeEntry = entry;
    _topNoticeTimer = Timer(const Duration(seconds: 2), () async {
      if (_topNoticeEntry != entry) return;
      await key.currentState?.dismiss();
      if (_topNoticeEntry == entry) {
        entry.remove();
        _topNoticeEntry = null;
      }
    });
  }

  Future<void> _refreshSub(Subscription sub) async {
    if (_refreshing.contains(sub.id)) return;
    setState(() => _refreshing.add(sub.id));
    final messenger = ScaffoldMessenger.of(context);
    _showSnack(
      messenger,
      'Обновление подписки...',
      isError: false,
      type: _TopNoticeType.info,
    );
    try {
      final result = await ImportService.importFromSubscriptionUrl(sub.url);
      if (!mounted) return;
      if (result.result == ImportResult.success) {
        final oldServers = StorageService.getServers()
            .where((s) => s.subscriptionId == sub.id)
            .toList();
        for (final s in oldServers) {
          await StorageService.deleteServer(s.id);
        }
        final newServers = result.configs.map((c) {
          c.subscriptionId = sub.id;
          return c;
        }).toList();
        await StorageService.saveServers(newServers);
        if (newServers.isNotEmpty && mounted) {
          context.read<VpnProvider>().selectServer(newServers.first);
        }
        sub.lastUpdated = DateTime.now();
        sub.serverCount = newServers.length;
        if (result.profileTitle != null) sub.name = result.profileTitle!;
        if (result.uploadBytes != null) sub.uploadBytes = result.uploadBytes;
        if (result.downloadBytes != null) {
          sub.downloadBytes = result.downloadBytes;
        }
        if (result.totalBytes != null) sub.totalBytes = result.totalBytes;
        if (result.expireTimestamp != null) {
          sub.expireTimestamp = result.expireTimestamp;
        }
        sub.description = result.description;
        await StorageService.saveSubscription(sub);
        _showSnack(
          messenger,
          'Подписка обновлена: ${newServers.length} серверов',
          isError: false,
        );
      } else {
        _showSnack(messenger, result.error ?? 'Ошибка обновления подписки');
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing.remove(sub.id));
      } else {
        _refreshing.remove(sub.id);
      }
      _loadAll();
    }
  }

  Future<void> _deleteSub(Subscription sub) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: c.cardBackground,
          title:
              Text('Удалить подписку?', style: TextStyle(color: c.textPrimary)),
          content: Text(
            '${sub.name}\n\nВсе серверы из этой подписки будут удалены.',
            style: TextStyle(color: c.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Отмена', style: TextStyle(color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить',
                  style: TextStyle(color: AppColors.error)),
            ),
          ],
        );
      },
    );
    if (confirm == true) {
      await StorageService.deleteSubscription(sub.id);
      _loadAll();
    }
  }

  Future<bool> _confirmDeleteServer(ServerConfig server) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: c.cardBackground,
          title:
              Text('Удалить сервер?', style: TextStyle(color: c.textPrimary)),
          content: Text(server.displayName,
              style: TextStyle(color: c.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Отмена', style: TextStyle(color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить',
                  style: TextStyle(color: AppColors.error)),
            ),
          ],
        );
      },
    );
    return confirm == true;
  }

  Future<void> _checkTcpPingForSubscription(Subscription sub) async {
    if (_checkingPing.contains(sub.id)) return;
    final targetServers =
        _servers.where((s) => s.subscriptionId == sub.id).toList();
    if (targetServers.isEmpty) {
      _showSnack(
        ScaffoldMessenger.of(context),
        'Нет серверов в подписке "${sub.name}"',
      );
      return;
    }

    setState(() {
      _checkingPing.add(sub.id);
      for (final server in targetServers) {
        _tcpPingByServerId[server.id] = null;
      }
    });

    final messenger = ScaffoldMessenger.of(context);
    _showSnack(
      messenger,
      'Проверка TCP ping: ${sub.name}...',
      isError: false,
      type: _TopNoticeType.info,
    );

    int okCount = 0;
    try {
      for (final server in targetServers) {
        final ping = await _measureTcpPing(server.host, server.port);
        if (!mounted) return;
        if (ping != null) okCount++;
        setState(() {
          _tcpPingByServerId[server.id] = ping;
        });
      }

      if (!mounted) return;
      _showSnack(
        messenger,
        'Пинг ${sub.name}: $okCount/${targetServers.length}',
        isError: false,
      );
    } finally {
      if (mounted) {
        setState(() => _checkingPing.remove(sub.id));
      } else {
        _checkingPing.remove(sub.id);
      }
    }
  }

  Future<int?> _measureTcpPing(String host, int port) async {
    final sw = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      return ms <= 0 ? 1 : ms;
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }
}

// ─── Subscription Card ────────────────────────────────────────────────────────

class _SubCard extends StatelessWidget {
  final Subscription subscription;
  final bool isRefreshing;
  final bool isCheckingPing;
  final VoidCallback onRefresh;
  final VoidCallback onCheckPing;
  final VoidCallback onDelete;

  const _SubCard({
    required this.subscription,
    required this.isRefreshing,
    required this.isCheckingPing,
    required this.onRefresh,
    required this.onCheckPing,
    required this.onDelete,
  });

  static const _months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];

  String _fmtGb(int bytes) {
    final gb = bytes / (1024 * 1024 * 1024);
    return '${gb.toStringAsFixed(1).replaceAll('.', ',')} GB';
  }

  String _fmtDate(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${_months[d.month - 1]} ${d.year} $h:$m';
  }

  String _displayProjectName(String raw) {
    final value = raw.trim();
    return value.isEmpty ? 'Подписка' : value;
  }

  Color _trafficBarColor(double ratio) {
    if (ratio >= 0.9) return AppColors.error.withValues(alpha: 0.75);
    if (ratio >= 0.7) return AppColors.warning.withValues(alpha: 0.75);
    return AppColors.connected.withValues(alpha: 0.65);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final used = subscription.usedBytes;
    final total = subscription.totalBytes;
    final ratio =
        (total != null && total > 0) ? math.min(used / total, 1.0) : 0.0;
    final expireDate = subscription.expireDate;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _displayProjectName(subscription.name),
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Opacity(
              opacity: isRefreshing ? 0.55 : 1,
              child: InkWell(
                onTap: isRefreshing ? null : onRefresh,
                borderRadius: BorderRadius.circular(20),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.refresh_rounded,
                      size: 29, color: AppColors.accent),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Opacity(
              opacity: isCheckingPing ? 0.55 : 1,
              child: InkWell(
                onTap: isCheckingPing ? null : onCheckPing,
                borderRadius: BorderRadius.circular(20),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.bolt_rounded,
                      size: 27, color: AppColors.connected),
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.delete_outline_rounded,
                    size: 22, color: c.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Divider(height: 1, color: c.borderColor),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            height: 20,
            child: Stack(
              children: [
                Container(color: c.borderColor),
                FractionallySizedBox(
                  widthFactor: ratio.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _trafficBarColor(ratio),
                    ),
                  ),
                ),
                Center(
                  child: Text(
                    total != null
                        ? '${_fmtGb(used)}/${_fmtGb(total)}'
                        : '${_fmtGb(used)}/--',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            expireDate == null
                ? 'Активна до: --'
                : 'Активна до: ${_fmtDate(expireDate)}',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Locations Rows ───────────────────────────────────────────────────────────

class _ServerRow extends StatelessWidget {
  final ServerConfig server;
  final int? pingMs;
  final bool isSelected;
  final VoidCallback onTap;

  const _ServerRow({
    required this.server,
    required this.pingMs,
    required this.isSelected,
    required this.onTap,
  });

  static final RegExp _isoCodePrefix =
      RegExp(r'^([A-Za-z]{2})(?:[\s\-_:/|]+)(.+)$');

  String? get _leadingIsoCode {
    final match = _isoCodePrefix.firstMatch(server.displayName.trim());
    if (match == null) return null;
    return match.group(1)?.toUpperCase();
  }

  String? get _emojiFlag {
    final runes = server.displayName.runes.toList();
    if (runes.length >= 2 &&
        runes[0] >= 0x1F1E6 &&
        runes[0] <= 0x1F1FF &&
        runes[1] >= 0x1F1E6 &&
        runes[1] <= 0x1F1FF) {
      return String.fromCharCodes(runes.take(2));
    }
    return null;
  }

  String? get _flagCode {
    final runes = server.displayName.runes.toList();
    if (runes.length >= 2 &&
        runes[0] >= 0x1F1E6 &&
        runes[0] <= 0x1F1FF &&
        runes[1] >= 0x1F1E6 &&
        runes[1] <= 0x1F1FF) {
      final first = (runes[0] - 0x1F1E6) + 65;
      final second = (runes[1] - 0x1F1E6) + 65;
      return String.fromCharCodes([first, second]);
    }
    return _leadingIsoCode;
  }

  String get _name {
    final flag = _emojiFlag;
    if (flag != null &&
        server.displayName.runes.length >= 2 &&
        server.displayName.runes.first >= 0x1F1E6 &&
        server.displayName.runes.first <= 0x1F1FF) {
      return server.displayName.substring(flag.length).trim();
    }
    final match = _isoCodePrefix.firstMatch(server.displayName.trim());
    if (match != null) {
      return match.group(2)?.trim() ?? server.displayName;
    }
    return server.displayName;
  }

  String get _subtitle => server.protocolUpper;
  String get _pingText => pingMs == null ? '--' : '$pingMs ms';

  Color _pingColor(Color fallback) {
    if (pingMs == null) return fallback;
    if (pingMs! < 100) return AppColors.connected;
    if (pingMs! < 300) return AppColors.warning;
    return AppColors.error;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final flag = _emojiFlag;
    final flagCode = _flagCode;
    final name = _name;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accent.withValues(alpha: 0.13)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: flagCode != null
                  ? CountryFlag.fromCountryCode(
                      flagCode,
                      theme: const ImageTheme(
                        width: 38,
                        height: 38,
                        shape: Circle(),
                      ),
                    )
                  : flag != null
                      ? Text(
                          flag,
                          style: const TextStyle(
                            fontSize: 24,
                            fontFamily: 'Segoe UI Emoji',
                            height: 1.0,
                          ),
                        )
                      : Icon(Icons.public_rounded,
                          size: 24,
                          color: isSelected ? AppColors.accent : c.textSecondary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.isNotEmpty ? name : server.displayName,
                    style: TextStyle(
                      color: isSelected ? AppColors.accent : c.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _subtitle,
                    style: TextStyle(
                      color: isSelected ? AppColors.accentGlow.withValues(alpha: 0.7) : c.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _pingText,
              style: TextStyle(
                color: isSelected
                    ? AppColors.accentGlow.withValues(alpha: 0.8)
                    : _pingColor(c.textSecondary),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Top Notice animated host ─────────────────────────────────────────────────

class _TopNoticeHost extends StatefulWidget {
  final Widget child;
  const _TopNoticeHost({super.key, required this.child});

  @override
  State<_TopNoticeHost> createState() => _TopNoticeHostState();
}

class _TopNoticeHostState extends State<_TopNoticeHost>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.8),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  Future<void> dismiss() async {
    if (_ctrl.isDismissed) return;
    await _ctrl.reverse();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: widget.child,
      ),
    );
  }
}

// ─── AppBar icon button ───────────────────────────────────────────────────────

class _AppBarButton extends StatelessWidget {
  final IconData icon;
  final double iconSize;

  const _AppBarButton({required this.icon, required this.iconSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.32),
        ),
      ),
      child: Icon(icon, color: AppColors.accent, size: iconSize),
    );
  }
}

// ─── Watermark background ──────────────────────────────────────────────────────

class _WatermarkPainter extends CustomPainter {
  final Color color;
  const _WatermarkPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const text = 'ChrNet';
    const fontSize = 20.0;
    const spacingX = 120.0;
    const spacingY = 75.0;
    const angle = -math.pi / 6;

    final textStyle = TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
    );

    final tp = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    final diagonal =
        math.sqrt(size.width * size.width + size.height * size.height);
    final cols = (diagonal / spacingX).ceil() + 2;
    final rows = (diagonal / spacingY).ceil() + 2;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(angle);
    canvas.translate(-diagonal / 2, -diagonal / 2);

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final offset = Offset(
          col * spacingX + (row.isOdd ? spacingX / 2 : 0),
          row * spacingY,
        );
        tp.paint(canvas, offset);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WatermarkPainter old) => old.color != color;
}
