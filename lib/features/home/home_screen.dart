import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/server_config.dart';
import '../../core/models/subscription.dart';
import '../../core/models/vpn_stats.dart';
import '../../core/services/deep_link_service.dart';
import '../../core/services/import_service.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/subscription_service.dart';
import '../../core/services/vpn_provider.dart';
import '../../core/utils/tcp_ping.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/app_card.dart';
import '../../ui/widgets/app_nav_bar.dart';
import '../../ui/widgets/country_flag_icon.dart';
import '../../ui/widgets/power_button.dart';
import '../../ui/widgets/stats_card.dart';
import '../servers/add_server_sheet.dart' show QrScanScreen;
import '../settings/settings_screen.dart';

enum _TopNoticeType { info, success, error }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _proxyPingParallelism = 4;
  List<ServerConfig> _servers = [];
  List<Subscription> _subscriptions = [];
  final Set<String> _refreshing = {};
  final Set<String> _checkingPing = {};
  final Map<String, int?> _tcpPingByServerId = {};
  final Set<String> _pendingPingServerIds = {};
  final Set<String> _measuredPingServerIds = {};
  OverlayEntry? _topNoticeEntry;
  Timer? _topNoticeTimer;
  Timer? _subscriptionAutoRefreshTimer;
  StreamSubscription<String>? _deepLinkSub;
  bool _deepLinkProcessing = false;
  bool _autoRefreshInProgress = false;
  final Set<String> _collapsedSubs = {};

  @override
  void initState() {
    super.initState();
    _loadAll();
    _startSubscriptionAutoRefresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkDeepLink();
      unawaited(_refreshDueSubscriptions());
    });
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
    _subscriptionAutoRefreshTimer?.cancel();
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

  void _startSubscriptionAutoRefresh() {
    _subscriptionAutoRefreshTimer?.cancel();
    _subscriptionAutoRefreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_refreshDueSubscriptions()),
    );
  }

  Future<void> _refreshDueSubscriptions() async {
    if (!mounted || _autoRefreshInProgress) return;

    final intervalHours = StorageService.getSubscriptionAutoUpdateHours();
    if (intervalHours <= 0) return;

    final now = DateTime.now();
    final dueSubscriptions = StorageService.getSubscriptions().where((sub) {
      final lastUpdated = sub.lastUpdated;
      if (lastUpdated == null) return true;
      return now.difference(lastUpdated) >= Duration(hours: intervalHours);
    }).toList();

    if (dueSubscriptions.isEmpty) return;

    _autoRefreshInProgress = true;
    try {
      final vpn = context.read<VpnProvider>();
      var hasChanges = false;

      for (final sub in dueSubscriptions) {
        final result = await SubscriptionService.refreshSubscription(sub);
        if (!mounted) return;
        if (!result.success) continue;

        hasChanges = true;
        if (result.replacementSelectedServer != null) {
          vpn.selectServer(result.replacementSelectedServer!);
        }
      }

      if (hasChanges && mounted) {
        _loadAll();
      }
    } finally {
      _autoRefreshInProgress = false;
    }
  }

  void _syncPingCache() {
    final activeServerIds = _servers.map((server) => server.id).toSet();
    final next = <String, int?>{};
    for (final server in _servers) {
      next[server.id] = _tcpPingByServerId[server.id];
    }
    _tcpPingByServerId
      ..clear()
      ..addAll(next);
    _pendingPingServerIds.removeWhere((id) => !activeServerIds.contains(id));
    _measuredPingServerIds.removeWhere((id) => !activeServerIds.contains(id));
  }

  /// The server the connect button will actually use: the explicit selection,
  /// or the first one in the list when nothing has been picked yet.
  ServerConfig? _effectiveServer(VpnProvider vpn) {
    final selected = vpn.selectedServer;
    if (selected != null) {
      final match = _servers.where((s) => s.id == selected.id).firstOrNull;
      if (match != null) return match;
    }
    return _servers.firstOrNull;
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnProvider>(
      builder: (context, vpn, _) {
        final width = MediaQuery.sizeOf(context).width;
        final isWide = width >= 960;

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: isWide ? 1120 : 640),
                child: isWide
                    ? _buildWideLayout(context, vpn)
                    : _buildCompactLayout(context, vpn),
              ),
            ),
          ),
          bottomNavigationBar: AppNavBar(
            activeTab: AppNavTab.connection,
            onConnectionTap: () {},
            onSettingsTap: _openSettings,
          ),
        );
      },
    );
  }

  Widget _buildCompactLayout(BuildContext context, VpnProvider vpn) {
    final height = MediaQuery.sizeOf(context).height;
    // Shrink the dial on short screens so the server list still shows above the
    // fold instead of being pushed off it.
    final buttonSize = height < 700 ? 140.0 : 168.0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.sm,
        AppSpacing.page,
        AppSpacing.xxl,
      ),
      children: [
        _buildHeader(context),
        const SizedBox(height: AppSpacing.lg),
        _buildHero(context, vpn, buttonSize: buttonSize),
        const SizedBox(height: AppSpacing.xl),
        ..._buildLibrary(context, vpn),
      ],
    );
  }

  Widget _buildWideLayout(BuildContext context, VpnProvider vpn) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xxl,
        AppSpacing.sm,
        AppSpacing.xxl,
        AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          const SizedBox(height: AppSpacing.xl),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 360,
                child: _buildHero(context, vpn, buttonSize: 184),
              ),
              const SizedBox(width: AppSpacing.xl),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildLibrary(context, vpn),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final c = AppColors.of(context);
    final supportsQrScan =
        Theme.of(context).platform == TargetPlatform.android ||
            Theme.of(context).platform == TargetPlatform.iOS;
    final showSubscriptionSiteButton =
        kIsWeb || defaultTargetPlatform != TargetPlatform.android;

    return Row(
      children: [
        Expanded(
          child: Text(
            'ChrNet',
            style: AppText.title.copyWith(color: c.textPrimary),
          ),
        ),
        if (showSubscriptionSiteButton)
          AppIconButton(
            icon: Icons.manage_accounts_outlined,
            tooltip: 'Личный кабинет',
            onTap: _openSubscriptionSite,
          ),
        PopupMenuButton<String>(
          tooltip: 'Добавить конфигурацию',
          position: PopupMenuPosition.under,
          onSelected: (value) async {
            if (value == 'clipboard') {
              final messenger = ScaffoldMessenger.of(context);
              final result = await ImportService.importFromClipboard();
              _handleImportResult(messenger, result);
            } else if (value == 'qr' && supportsQrScan) {
              if (!context.mounted) return;
              final messenger = ScaffoldMessenger.of(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => QrScanScreen(
                    onScanned: (uri) async {
                      final result = await ImportService.importFromText(uri);
                      _handleImportResult(messenger, result);
                    },
                  ),
                ),
              );
            }
          },
          itemBuilder: (context) => [
            _menuItem(
              context,
              value: 'clipboard',
              icon: Icons.content_paste_rounded,
              label: 'Из буфера обмена',
            ),
            if (supportsQrScan)
              _menuItem(
                context,
                value: 'qr',
                icon: Icons.qr_code_scanner_rounded,
                label: 'Сканировать QR-код',
              ),
          ],
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            decoration: BoxDecoration(
              color: c.accentText,
              borderRadius: AppRadius.mdAll,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add_rounded,
                  size: 19,
                  color: c.isDark ? const Color(0xFF04211E) : Colors.white,
                ),
                const SizedBox(width: 5),
                Text(
                  'Добавить',
                  style: AppText.body.copyWith(
                    color: c.isDark ? const Color(0xFF04211E) : Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
    BuildContext context, {
    required String value,
    required IconData icon,
    required String label,
  }) {
    final c = AppColors.of(context);
    return PopupMenuItem<String>(
      value: value,
      height: 46,
      child: Row(
        children: [
          Icon(icon, color: c.accentText, size: 19),
          const SizedBox(width: AppSpacing.md),
          Text(label, style: AppText.body.copyWith(color: c.textPrimary)),
        ],
      ),
    );
  }

  // ─── Hero ─────────────────────────────────────────────────────────────────

  Widget _buildHero(
    BuildContext context,
    VpnProvider vpn, {
    required double buttonSize,
  }) {
    final c = AppColors.of(context);
    final isConnected = vpn.status == VpnStatus.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Connected replaces the status label with the session timer — the
        // running clock says "protected" better than the word does.
        Center(
          child: isConnected
              ? Text(
                  _formatDuration(vpn.stats.connectedDuration),
                  style: AppText.mono.copyWith(
                    color: c.textPrimary,
                    fontSize: 26,
                    letterSpacing: 2,
                  ),
                )
              : _buildStatusPill(context, vpn),
        ),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: PowerButton(
            status: vpn.status,
            size: buttonSize,
            onTap: () {
              if (_servers.isEmpty) {
                _showSnack(
                  ScaffoldMessenger.of(context),
                  'Сначала добавьте конфигурацию',
                );
                return;
              }
              if (vpn.selectedServer == null) {
                vpn.selectServer(_servers.first);
              }
              vpn.toggleConnection();
            },
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // One fixed-height slot for both states — the throughput line when
        // connected, the hint otherwise — so the list below never shifts.
        SizedBox(
          height: 22,
          child: Center(
            child: isConnected
                ? StatsCard(stats: vpn.stats)
                : Text(
                    _heroHint(vpn),
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(color: c.textSecondary),
                  ),
          ),
        ),
        if (vpn.errorMessage != null) ...[
          const SizedBox(height: AppSpacing.md),
          _buildErrorBanner(context, vpn.errorMessage!),
        ],
      ],
    );
  }

  String _heroHint(VpnProvider vpn) {
    if (_servers.isEmpty) return 'Добавьте конфигурацию, чтобы начать';
    return switch (vpn.status) {
      VpnStatus.connecting => 'Устанавливаем защищённое соединение',
      VpnStatus.disconnecting => 'Закрываем туннель',
      VpnStatus.error => 'Попробуйте другой сервер',
      _ => 'Нажмите, чтобы подключиться',
    };
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Widget _buildStatusPill(BuildContext context, VpnProvider vpn) {
    final c = AppColors.of(context);
    final (label, color, background) = switch (vpn.status) {
      VpnStatus.connected => ('Защищено', c.connectedText, c.successSoft),
      VpnStatus.connecting => ('Подключение', c.accentText, c.accentSoft),
      VpnStatus.disconnecting => ('Отключение', c.textSecondary, c.surfaceMuted),
      VpnStatus.error => ('Ошибка', c.errorText, c.errorSoft),
      VpnStatus.disconnected => ('Не подключено', c.textSecondary, c.surfaceMuted),
    };

    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            label,
            style: AppText.body.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, String message) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.errorSoft,
        borderRadius: AppRadius.mdAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: c.errorText),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: AppText.caption.copyWith(color: c.errorText),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Subscriptions & servers ──────────────────────────────────────────────

  List<Widget> _buildLibrary(BuildContext context, VpnProvider vpn) {
    if (_servers.isEmpty && _subscriptions.isEmpty) {
      return [_buildEmpty(context)];
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

    final children = <Widget>[];

    if (_subscriptions.isNotEmpty) {
      children.add(
        AppSectionLabel(
          text: 'Подписки',
          trailing: Text(
            '${_subscriptions.length}',
            style: AppText.overline.copyWith(
              color: AppColors.of(context).textDisabled,
            ),
          ),
        ),
      );
      for (final sub in _subscriptions) {
        children.add(
          _buildSubscriptionCard(
            context,
            vpn,
            sub,
            bySubId[sub.id] ?? const <ServerConfig>[],
          ),
        );
        children.add(const SizedBox(height: AppSpacing.md));
      }
    }

    if (orphanServers.isNotEmpty) {
      children.add(const AppSectionLabel(text: 'Отдельные серверы'));
      children.add(
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: _buildServerRows(vpn, orphanServers)),
        ),
      );
      children.add(const SizedBox(height: AppSpacing.md));
    }

    if (children.isNotEmpty) children.removeLast();
    return children;
  }

  Widget _buildSubscriptionCard(
    BuildContext context,
    VpnProvider vpn,
    Subscription sub,
    List<ServerConfig> subServers,
  ) {
    final c = AppColors.of(context);
    final isCollapsed = _collapsedSubs.contains(sub.id);
    final children = <Widget>[
      _SubCard(
        subscription: sub,
        isRefreshing: _refreshing.contains(sub.id),
        isCheckingPing: _checkingPing.contains(sub.id),
        isCollapsed: isCollapsed,
        onRefresh: () => _refreshSub(sub),
        onCheckPing: () => _checkTcpPingForSubscription(sub),
        onDelete: () => _deleteSub(sub),
        onToggleCollapse: () => setState(() {
          if (isCollapsed) {
            _collapsedSubs.remove(sub.id);
          } else {
            _collapsedSubs.add(sub.id);
          }
        }),
      ),
    ];

    if (!isCollapsed) {
      final infoLines = _locationInfoLines(sub);
      if (infoLines.isNotEmpty) {
        children.add(Divider(height: 1, color: c.border));
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: _buildLocationsInfo(context, infoLines),
          ),
        );
      }

      if (subServers.isNotEmpty) {
        children.add(Divider(height: 1, color: c.border));
        children.addAll(_buildServerRows(vpn, subServers));
      }
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: AnimatedSize(
        duration: AppMotion.normal,
        curve: AppMotion.curve,
        alignment: Alignment.topCenter,
        child: Column(children: children),
      ),
    );
  }

  List<Widget> _buildServerRows(VpnProvider vpn, List<ServerConfig> servers) {
    final c = AppColors.of(context);
    final effectiveId = _effectiveServer(vpn)?.id;

    return servers.asMap().entries.map((entry) {
      final index = entry.key;
      final server = entry.value;
      return Column(
        children: [
          if (index > 0) Divider(height: 1, indent: 62, color: c.border),
          Dismissible(
            key: Key('server_${server.id}'),
            direction: DismissDirection.endToStart,
            confirmDismiss: (_) => _confirmDeleteServer(server),
            onDismissed: (_) async {
              await StorageService.deleteServer(server.id);
              _loadServers();
            },
            background: ColoredBox(
              color: c.errorSoft,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.xl),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    color: c.errorText,
                    size: 22,
                  ),
                ),
              ),
            ),
            child: _ServerRow(
              server: server,
              pingMs: _tcpPingByServerId[server.id],
              isPingLoading: _pendingPingServerIds.contains(server.id),
              hasMeasuredPing: _measuredPingServerIds.contains(server.id),
              isSelected: effectiveId == server.id,
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

  List<String> _locationInfoLines(Subscription? activeSub) {
    if (activeSub == null) return const [];
    return activeSub.description
        .map((line) => line.trim())
        .where((line) =>
            line.isNotEmpty && !_isEmailLine(line) && !_isTelegramIdLine(line))
        .toList();
  }

  Widget _buildLocationsInfo(BuildContext context, List<String> lines) {
    final c = AppColors.of(context);
    // Email и TG ID отображаются внутри _SubCard — здесь их пропускаем
    final filtered =
        lines.where((l) => !_isEmailLine(l) && !_isTelegramIdLine(l)).toList();
    if (filtered.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < filtered.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.xs),
          Text(
            filtered[i],
            style: AppText.caption.copyWith(
              color: filtered[i].toLowerCase().contains('осталось')
                  ? c.textPrimary
                  : c.textSecondary,
              fontSize: 12.5,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final c = AppColors.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xxl,
        AppSpacing.xl,
        AppSpacing.xl,
      ),
      child: Column(
        children: [
          AppIconPlate(
            icon: Icons.public_rounded,
            color: c.accentText,
            size: 52,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Нет конфигураций',
            textAlign: TextAlign.center,
            style: AppText.heading.copyWith(color: c.textPrimary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Скопируйте ссылку подписки или vless://-ключ '
            'и вставьте его из буфера обмена.',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final result = await ImportService.importFromClipboard();
              _handleImportResult(messenger, result);
            },
            icon: const Icon(Icons.content_paste_rounded, size: 18),
            label: const Text('Вставить из буфера'),
          ),
        ],
      ),
    );
  }

  // ─── Actions ──────────────────────────────────────────────────────────────

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
          existing.dnsServers = res.dnsServers;
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
            dnsServers: res.dnsServers,
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
    final key = GlobalKey<_TopNoticeHostState>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final c = AppColors.of(ctx);
        final safeTop = MediaQuery.of(ctx).padding.top + AppSpacing.sm;
        final (iconData, iconColor) = switch (type) {
          _TopNoticeType.info => (Icons.info_outline_rounded, c.infoText),
          _TopNoticeType.success => (Icons.check_rounded, c.connectedText),
          _TopNoticeType.error => (Icons.close_rounded, c.errorText),
        };

        return Positioned(
          top: safeTop,
          left: AppSpacing.page,
          right: AppSpacing.page,
          child: _TopNoticeHost(
            key: key,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: AppRadius.mdAll,
                    border: Border.all(color: c.border),
                    boxShadow: c.floatingShadow,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(iconData, size: 18, color: iconColor),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Text(
                          message,
                          style: AppText.body.copyWith(
                            color: c.textPrimary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
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
      final result = await SubscriptionService.refreshSubscription(sub);
      if (!mounted) return;
      if (result.success) {
        if (result.replacementSelectedServer != null) {
          context.read<VpnProvider>().selectServer(
                result.replacementSelectedServer!,
              );
        }
        _showSnack(
          messenger,
          'Подписка обновлена: ${result.servers.length} серверов',
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
    final confirm = await _confirm(
      title: 'Удалить подписку?',
      message: '${sub.name}\n\nВсе серверы из этой подписки будут удалены.',
    );
    if (confirm) {
      await StorageService.deleteSubscription(sub.id);
      _loadAll();
    }
  }

  Future<bool> _confirmDeleteServer(ServerConfig server) => _confirm(
        title: 'Удалить сервер?',
        message: server.displayName,
      );

  Future<bool> _confirm({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(foregroundColor: c.textSecondary),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: c.errorText),
              child: const Text('Удалить'),
            ),
          ],
        );
      },
    );
    return result == true;
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
        _pendingPingServerIds.add(server.id);
        _measuredPingServerIds.remove(server.id);
      }
    });

    final messenger = ScaffoldMessenger.of(context);
    _showSnack(
      messenger,
      'Проверка ping: ${sub.name}...',
      isError: false,
      type: _TopNoticeType.info,
    );

    try {
      final results = <int?>[];
      final pingMethod = StorageService.getPingMethod();
      final useProxyPing = _isProxyPingMethod(pingMethod);

      Future<int?> measureAndStore(ServerConfig server) async {
        final ping = await _measureServerPing(server);
        if (mounted) {
          setState(() {
            _tcpPingByServerId[server.id] = ping;
            _pendingPingServerIds.remove(server.id);
            _measuredPingServerIds.add(server.id);
          });
        } else {
          _tcpPingByServerId[server.id] = ping;
          _pendingPingServerIds.remove(server.id);
          _measuredPingServerIds.add(server.id);
        }
        return ping;
      }

      if (useProxyPing) {
        results.addAll(
          await _measureServersWithLimit(
            targetServers,
            parallelism: _proxyPingParallelism,
            measure: measureAndStore,
          ),
        );
      } else {
        results.addAll(
          await Future.wait(targetServers.map(measureAndStore)),
        );
      }

      final okCount = results.whereType<int>().length;
      final failCount = results.length - okCount;

      if (!mounted) return;
      _showSnack(
        messenger,
        'Пинг ${sub.name}: $okCount/${targetServers.length}'
        '${failCount > 0 ? ', недоступно: $failCount' : ''}',
        isError: false,
      );
    } catch (error, stackTrace) {
      debugPrint('Ping failed for subscription ${sub.id}: $error\n$stackTrace');
      if (!mounted) return;
      _showSnack(
        messenger,
        'Не удалось завершить проверку ping',
      );
    } finally {
      if (mounted) {
        setState(() {
          _checkingPing.remove(sub.id);
          for (final server in targetServers) {
            _pendingPingServerIds.remove(server.id);
          }
        });
      } else {
        _checkingPing.remove(sub.id);
        for (final server in targetServers) {
          _pendingPingServerIds.remove(server.id);
        }
      }
    }
  }

  Future<List<int?>> _measureServersWithLimit(
    List<ServerConfig> servers, {
    required int parallelism,
    required Future<int?> Function(ServerConfig server) measure,
  }) async {
    if (servers.isEmpty) {
      return const [];
    }

    final results = List<int?>.filled(servers.length, null);
    var nextIndex = 0;
    final workerCount =
        parallelism < servers.length ? parallelism : servers.length;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= servers.length) {
          return;
        }
        nextIndex++;
        results[index] = await measure(servers[index]);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results;
  }

  Future<int?> _measureServerPing(ServerConfig server) async {
    final pingMethod = StorageService.getPingMethod();
    if (_isProxyPingMethod(pingMethod)) {
      // Every supported server is VLESS over a TCP-based transport now, so the
      // TCP probe always applies — the UDP-only exception went out with
      // Hysteria.
      final tcpPing = await measureTcpPing(server.host, server.port);
      if (tcpPing != null) {
        return tcpPing;
      }

      final testUri = Uri.tryParse(StorageService.getPingTestUrl());
      if (testUri != null &&
          (testUri.scheme == 'http' || testUri.scheme == 'https')) {
        final ping = await measureProxyHttpPing(
          server,
          testUri: testUri,
          method:
              pingMethod == StorageService.pingMethodProxyHead ? 'HEAD' : 'GET',
        );
        if (ping != null) {
          return ping;
        }
      }
      return measureTcpPing(server.host, server.port);
    }

    if (pingMethod == StorageService.pingMethodIcmp) {
      final ping = await measureIcmpPing(server.host);
      if (ping != null) {
        return ping;
      }
      return measureTcpPing(server.host, server.port);
    }

    return measureTcpPing(server.host, server.port);
  }

  bool _isProxyPingMethod(String method) {
    return method == StorageService.pingMethodProxyGet ||
        method == StorageService.pingMethodProxyHead;
  }

  void _openSettings() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: AppMotion.normal,
        reverseTransitionDuration: AppMotion.fast,
        pageBuilder: (_, __, ___) => const SettingsScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: AppMotion.curve,
            reverseCurve: Curves.easeInCubic,
          );

          return ColoredBox(
            color: AppColors.of(context).background,
            child: FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            ),
          );
        },
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
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

bool _isEmailLine(String line) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(line.trim());

bool _isTelegramIdLine(String line) {
  final t = line.trim();
  return RegExp(r'^user_\d+$').hasMatch(t) ||
      RegExp(r'^@\w+$').hasMatch(t) ||
      RegExp(r'^\d{5,}$').hasMatch(t);
}

/// Splits a display name into its country flag / ISO prefix and the rest.
class _ServerLabel {
  static final RegExp _isoCodePrefix =
      RegExp(r'^([A-Za-z]{2})(?:[\s\-_:/|]+)(.+)$');

  final ServerConfig server;

  const _ServerLabel(this.server);

  String? get emojiFlag {
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

  String? get flagCode {
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
    final match = _isoCodePrefix.firstMatch(server.displayName.trim());
    return match?.group(1)?.toUpperCase();
  }

  String get _name {
    final flag = emojiFlag;
    if (flag != null) {
      return server.displayName.substring(flag.length).trim();
    }
    final match = _isoCodePrefix.firstMatch(server.displayName.trim());
    if (match != null) {
      return match.group(2)?.trim() ?? server.displayName;
    }
    return server.displayName;
  }

  bool get isUnnamedKey {
    final rawName = server.name.trim();
    if (rawName.isEmpty) return true;
    return rawName == '${server.host}:${server.port}';
  }

  String get title {
    if (isUnnamedKey) return 'Ключ ${server.protocolUpper}';
    final name = _name;
    return name.isNotEmpty ? name : server.displayName;
  }

  String get subtitle =>
      isUnnamedKey ? '${server.host}:${server.port}' : server.protocolUpper;

  /// The leading avatar: a flag when the name carries one, otherwise an icon.
  Widget buildAvatar(BuildContext context, {double size = 38}) {
    final c = AppColors.of(context);
    final code = flagCode;
    if (code != null) {
      return CountryFlagIcon(countryCode: code, size: size);
    }
    return AppIconPlate(
      icon: isUnnamedKey ? Icons.vpn_key_rounded : Icons.public_rounded,
      color: c.textSecondary,
      background: c.surfaceMuted,
      size: size,
    );
  }
}

Color _pingColor(AppColors c, int ms) {
  if (ms <= 120) return c.connectedText;
  if (ms <= 300) return c.warningText;
  return c.errorText;
}

// ─── Subscription header ──────────────────────────────────────────────────────

class _SubCard extends StatelessWidget {
  final Subscription subscription;
  final bool isRefreshing;
  final bool isCheckingPing;
  final bool isCollapsed;
  final VoidCallback onRefresh;
  final VoidCallback onCheckPing;
  final VoidCallback onDelete;
  final VoidCallback onToggleCollapse;

  const _SubCard({
    required this.subscription,
    required this.isRefreshing,
    required this.isCheckingPing,
    required this.isCollapsed,
    required this.onRefresh,
    required this.onCheckPing,
    required this.onDelete,
    required this.onToggleCollapse,
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
    return '${gb.toStringAsFixed(1).replaceAll('.', ',')} ГБ';
  }

  String _fmtDate(DateTime d) =>
      '${d.day} ${_months[d.month - 1]} ${d.year}';

  String _displayProjectName(String raw) {
    final value = raw.trim();
    return value.isEmpty ? 'Подписка' : value;
  }

  Color _trafficColor(AppColors c, double ratio) {
    if (ratio >= 0.9) return c.errorText;
    if (ratio >= 0.7) return c.warningText;
    return c.accentText;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final used = subscription.usedBytes;
    final total = subscription.totalBytes;
    final ratio =
        (total != null && total > 0) ? math.min(used / total, 1.0) : 0.0;
    final expireDate = subscription.expireDate;
    final barColor = _trafficColor(c, ratio);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onToggleCollapse,
                  borderRadius: AppRadius.smAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm,
                      horizontal: AppSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: isCollapsed ? -0.25 : 0,
                          duration: AppMotion.normal,
                          child: Icon(
                            Icons.expand_more_rounded,
                            size: 20,
                            color: c.textSecondary,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _displayProjectName(subscription.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.heading.copyWith(
                              color: c.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AppIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Обновить подписку',
                isBusy: isRefreshing,
                onTap: onRefresh,
                size: 38,
              ),
              AppIconButton(
                icon: Icons.bolt_rounded,
                tooltip: 'Проверить ping',
                isBusy: isCheckingPing,
                onTap: onCheckPing,
                size: 38,
              ),
              AppIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Удалить подписку',
                onTap: onDelete,
                size: 38,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Трафик',
                      style: AppText.caption.copyWith(
                        color: c.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      total != null
                          ? '${_fmtGb(used)} из ${_fmtGb(total)}'
                          : _fmtGb(used),
                      style: AppText.mono.copyWith(
                        color: c.textPrimary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 6,
                    backgroundColor: c.surfaceMuted,
                    valueColor: AlwaysStoppedAnimation(barColor),
                  ),
                ),
                if (expireDate != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _buildExpiry(c, expireDate),
                ],
                if (_userInfoPills(c).isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: _userInfoPills(c),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Expiry as a plain label/value row, matching the traffic line above it.
  Widget _buildExpiry(AppColors c, DateTime expireDate) {
    final days = expireDate.difference(DateTime.now()).inDays;
    final expired = days < 0;
    final valueColor = expired || days <= 3
        ? c.errorText
        : days <= 14
            ? c.warningText
            : c.textPrimary;

    return Row(
      children: [
        Text(
          expired ? 'Истекла' : 'Истекает',
          style: AppText.caption.copyWith(
            color: c.textSecondary,
            fontSize: 12.5,
          ),
        ),
        const Spacer(),
        Text(
          _fmtDate(expireDate),
          style: AppText.mono.copyWith(color: valueColor, fontSize: 12.5),
        ),
      ],
    );
  }

  List<Widget> _userInfoPills(AppColors c) {
    final lines = subscription.description
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final tgId = lines.where(_isTelegramIdLine).firstOrNull;
    final email = lines.where(_isEmailLine).firstOrNull;

    final label = tgId != null ? 'TG ID: $tgId' : email;
    if (label == null) return const [];

    return [
      AppPill(
        icon: Icons.person_outline_rounded,
        label: label,
        color: c.textSecondary,
        background: c.surfaceMuted,
      ),
    ];
  }
}

// ─── Server row ───────────────────────────────────────────────────────────────

class _ServerRow extends StatelessWidget {
  final ServerConfig server;
  final int? pingMs;
  final bool isPingLoading;
  final bool hasMeasuredPing;
  final bool isSelected;
  final VoidCallback onTap;

  const _ServerRow({
    required this.server,
    required this.pingMs,
    required this.isPingLoading,
    required this.hasMeasuredPing,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final label = _ServerLabel(server);

    return Material(
      color: isSelected ? c.accentSoft : c.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 10,
          ),
          child: Row(
            children: [
              label.buildAvatar(context),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        color: isSelected ? c.accentText : c.textPrimary,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      label.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: c.textDisabled,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _PingStatusLabel(
                pingMs: pingMs,
                isLoading: isPingLoading,
                hasMeasuredPing: hasMeasuredPing,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PingStatusLabel extends StatelessWidget {
  final int? pingMs;
  final bool isLoading;
  final bool hasMeasuredPing;

  const _PingStatusLabel({
    required this.pingMs,
    required this.isLoading,
    required this.hasMeasuredPing,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (isLoading) {
      return SizedBox(
        width: 44,
        child: Center(
          child: SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: c.textDisabled,
            ),
          ),
        ),
      );
    }

    final ms = pingMs;
    final (text, color) = ms != null
        ? ('$ms ms', _pingColor(c, ms))
        : hasMeasuredPing
            ? ('—', c.errorText)
            : ('', c.textDisabled);

    if (text.isEmpty) return const SizedBox(width: 44);

    return SizedBox(
      width: 44,
      child: Text(
        text,
        textAlign: TextAlign.right,
        style: AppText.mono.copyWith(color: color, fontSize: 12),
      ),
    );
  }
}

// ─── Top notice animated host ─────────────────────────────────────────────────

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
      duration: AppMotion.normal,
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.8),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: AppMotion.curve));
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
