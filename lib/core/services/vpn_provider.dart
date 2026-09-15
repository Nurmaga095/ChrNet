import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../models/server_config.dart';
import '../models/vpn_stats.dart';
import '../utils/host_resolver.dart';
import 'storage_service.dart';
import 'xray_config_builder.dart';

class VpnProvider extends ChangeNotifier with WidgetsBindingObserver {
  // ─── Platform channel для нативного Xray ─────────────────────────────────
  static const _channel = MethodChannel('com.chrnet.vpn/service');
  static const _statsChannel = EventChannel('com.chrnet.vpn/stats');

  /// Pauses between attempts to restore a connection that dropped by itself:
  /// the core crashed, the network changed or the service restarted.
  static const List<int> _autoReconnectDelaysSeconds = [2, 4, 8, 15, 30, 60];

  /// Start failures another attempt cannot fix; they are shown right away.
  static const Set<String> _permanentErrorCodes = {
    'INVALID_ARG',
    'INVALID_CONFIG',
    'XRAY_MISSING',
    'NOT_ELEVATED',
    'PORT_IN_USE',
    'PROXY_FAILED',
  };

  VpnStatus _status = VpnStatus.disconnected;
  VpnStats _stats = const VpnStats();
  ServerConfig? _selectedServer;
  String? _errorMessage;
  String? _statusDetail;
  StreamSubscription? _statsSubscription;
  Timer? _durationTimer;
  Timer? _connectingPollTimer;
  Timer? _autoReconnectTimer;
  Timer? _stableConnectionTimer;
  int _autoReconnectAttempt = 0;
  DateTime? _connectedAt;
  bool _serverSwitchInProgress = false;
  ServerConfig? _queuedServerSwitch;
  int _prevDownloadBytes = 0;
  int _prevUploadBytes = 0;
  final ListQueue<int> _downloadSpeedSamples = ListQueue<int>();
  final ListQueue<int> _uploadSpeedSamples = ListQueue<int>();

  VpnStatus get status => _status;
  VpnStats get stats => _stats;
  ServerConfig? get selectedServer => _selectedServer;
  String? get errorMessage => _errorMessage;

  /// Context for the current status, such as a dropped connection being
  /// restored. Null when the status speaks for itself.
  String? get statusDetail => _statusDetail;
  bool get isConnected => _status == VpnStatus.connected;
  bool get isConnecting => _status == VpnStatus.connecting;
  bool get _isVpnSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  VpnProvider() {
    _loadSelectedServer();
    _listenNativeStatus();
    unawaited(_initialize());
    unawaited(syncQuickSettingsConfig());
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _initialize() async {
    await _syncStatusWithNative();
    // Windows can start the app at sign-in; with auto-connect on, that brings
    // the VPN up without anyone opening the window.
    if (!_isWindows || !StorageService.getAutoConnect()) return;
    if (_status != VpnStatus.disconnected) return;
    if (_selectedServer == null) {
      final first = StorageService.getServers().firstOrNull;
      if (first == null) return;
      _selectedServer = first;
      await StorageService.setSelectedServerId(first.id);
    }
    await connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncStatusWithNative();
    }
  }

  void _loadSelectedServer() {
    final id = StorageService.getSelectedServerId();
    if (id != null) {
      final servers = StorageService.getServers();
      try {
        _selectedServer = servers.firstWhere((s) => s.id == id);
      } catch (_) {
        _selectedServer = servers.isNotEmpty ? servers.first : null;
      }
    }
  }

  void selectServer(ServerConfig server) {
    _queuedServerSwitch = server;
    if (_serverSwitchInProgress) return;
    unawaited(_drainServerSwitchQueue());
  }

  Future<void> _drainServerSwitchQueue() async {
    _serverSwitchInProgress = true;
    try {
      while (_queuedServerSwitch != null) {
        final targetServer = _queuedServerSwitch!;
        _queuedServerSwitch = null;
        await _selectServer(targetServer);
      }
    } finally {
      _serverSwitchInProgress = false;
    }
  }

  Future<void> _selectServer(ServerConfig server) async {
    final prevId = _selectedServer?.id;
    _selectedServer = server;
    notifyListeners();
    await StorageService.setSelectedServerId(server.id);
    await syncQuickSettingsConfig();

    // Если сервер реально сменился и VPN уже активен — перезапускаем туннель.
    if (prevId == server.id) return;
    unawaited(_updateTray());
    if (_status == VpnStatus.connected) {
      await reconnect();
      await _waitForConnectionTransition();
    }
  }

  Future<void> _waitForConnectionTransition({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (
        _status == VpnStatus.connecting || _status == VpnStatus.disconnecting) {
      if (DateTime.now().isAfter(deadline)) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  // ─── Sync status on app resume ───────────────────────────────────────────
  Future<void> _syncStatusWithNative() async {
    if (!_isVpnSupportedPlatform) return;
    try {
      var isRunning = false;
      DateTime? startedAt;
      if (_isWindows) {
        // The service keeps a connection alive across app restarts; its start
        // time keeps the session timer honest.
        final state =
            await _channel.invokeMapMethod<String, dynamic>('getCoreState');
        isRunning = state?['running'] == true;
        final startedAtMs = (state?['startedAt'] as num?)?.toInt() ?? 0;
        if (startedAtMs > 0) {
          startedAt = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
        }
      } else {
        isRunning = await _channel.invokeMethod<bool>('getStatus') == true;
      }

      if (isRunning &&
          (_status == VpnStatus.disconnected || _status == VpnStatus.error)) {
        _errorMessage = null;
        _connectedAt = startedAt ?? DateTime.now();
        _setStatus(VpnStatus.connected);
        _startStatsTracking();
      } else if (!isRunning && _status == VpnStatus.connected) {
        _stopStatsTracking();
        _stats = const VpnStats();
        _setStatus(VpnStatus.disconnected);
      }
    } catch (_) {}
  }

  // ─── Connect / Disconnect ─────────────────────────────────────────────────
  Future<void> toggleConnection() async {
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> connect() => _connect(automatic: false);

  /// [automatic] marks an attempt to restore a dropped connection; a failure
  /// then schedules the next attempt instead of showing an error.
  Future<void> _connect({required bool automatic}) async {
    if (!_isVpnSupportedPlatform) {
      _errorMessage = 'VPN-движок недоступен на этой платформе';
      _setStatus(VpnStatus.error);
      return;
    }
    if (_selectedServer == null) {
      _errorMessage = 'Выберите сервер';
      notifyListeners();
      return;
    }
    if (!automatic) {
      _cancelAutoReconnect();
      _statusDetail = null;
    }

    _errorMessage = null;
    _setStatus(VpnStatus.connecting);

    try {
      await syncQuickSettingsConfig();
      final payload = await _connectPayload();
      await _channel.invokeMethod('connect', payload);
      if (await _confirmWindowsCoreRunning()) return;
      // Polling: раз в секунду спрашиваем у сервиса — вдруг push не дошёл
      _startConnectingPoll();
    } on MissingPluginException {
      _failConnect('VPN-сервис недоступен', automatic: automatic);
    } on PlatformException catch (e) {
      _failConnect(
        e.message ?? 'Ошибка подключения',
        code: e.code,
        automatic: automatic,
      );
    } on UnsupportedError catch (e) {
      // Raised for servers saved before the app narrowed to VLESS. The message
      // is already user-facing, so show it instead of wrapping it in "Ошибка
      // подключения: Unsupported operation: ...".
      _failConnect(
        e.message?.toString() ?? 'Протокол не поддерживается',
        automatic: false,
      );
    } catch (e) {
      _failConnect('Ошибка подключения: $e', automatic: automatic);
    }
  }

  Future<void> reconnect() async {
    if (!_isVpnSupportedPlatform) {
      _errorMessage = 'VPN-движок недоступен на этой платформе';
      _setStatus(VpnStatus.error);
      return;
    }
    if (_selectedServer == null) {
      _errorMessage = 'Выберите сервер';
      notifyListeners();
      return;
    }

    _cancelAutoReconnect();
    _statusDetail = null;
    _stopStatsTracking();
    _stats = const VpnStats();
    _errorMessage = null;
    _setStatus(VpnStatus.connecting);

    try {
      await syncQuickSettingsConfig();
      final payload = await _connectPayload();
      await _channel.invokeMethod('reconnect', payload);
      if (await _confirmWindowsCoreRunning()) return;
      _startConnectingPoll();
    } on MissingPluginException {
      _failConnect('VPN-сервис недоступен', automatic: false);
    } on PlatformException catch (e) {
      _failConnect(e.message ?? 'Ошибка переподключения', automatic: false);
    } on UnsupportedError catch (e) {
      // Raised for servers saved before the app narrowed to VLESS. The message
      // is already user-facing, so show it instead of wrapping it in "Ошибка
      // переподключения: Unsupported operation: ...".
      _failConnect(
        e.message?.toString() ?? 'Протокол не поддерживается',
        automatic: false,
      );
    } catch (e) {
      _failConnect('Ошибка переподключения: $e', automatic: false);
    }
  }

  void _failConnect(String message, {String? code, required bool automatic}) {
    _connectingPollTimer?.cancel();
    if (automatic &&
        !_permanentErrorCodes.contains(code) &&
        _scheduleAutoReconnect()) {
      return;
    }
    _cancelAutoReconnect();
    _statusDetail = null;
    _errorMessage = message;
    _setStatus(VpnStatus.error);
  }

  Map<String, dynamic> _basePayload(ServerConfig server) => {
        'rawUri': server.rawUri,
        'ruRouting': StorageService.getRuRouting(),
        'serverName': server.displayName,
        'host': server.host,
        'port': server.port,
        'protocol': server.protocol,
        'uuid': server.uuid,
        'extras': server.extras,
      };

  /// The payload Android and the quick settings tile use.
  Map<String, dynamic> get _selectedServerPayload => {
        ..._basePayload(_selectedServer!),
        'configJson': _buildSelectedServerConfig(),
        'windowsMode': StorageService.getWindowsVpnMode(),
        'serverHosts': XrayConfigBuilder.tunnelBypassHosts(_selectedServer!),
      };

  Future<Map<String, dynamic>> _connectPayload() async {
    if (!_isWindows) return _selectedServerPayload;

    final server = _selectedServer!;
    final tunnel = StorageService.getWindowsVpnMode() == 'tunnel';
    final ruRouting = StorageService.getRuRouting();
    final hosts = XrayConfigBuilder.tunnelBypassHosts(server);
    // Resolved before the core starts: the service routes exactly these
    // addresses around the tunnel, and the pinned hosts keep the core from
    // dialling any other address of the same server.
    final pinned = tunnel
        ? await resolveIpv4Addresses(hosts)
        : const <String, List<String>>{};
    final configJson = tunnel
        ? XrayConfigBuilder.buildTunnelConfig(
            server,
            enableRuRouting: ruRouting,
            hijackDns: true,
            pinnedHosts: pinned,
            metricsPort: XrayConfigBuilder.windowsMetricsPort,
          )
        : XrayConfigBuilder.buildSystemProxyConfig(
            server,
            enableRuRouting: ruRouting,
            metricsPort: XrayConfigBuilder.windowsMetricsPort,
          );

    return {
      ..._basePayload(server),
      'configJson': configJson,
      'windowsMode': tunnel ? 'tunnel' : 'system_proxy',
      'serverHosts': <String>{
        ...hosts,
        for (final addresses in pinned.values) ...addresses,
      }.toList(),
      'proxyTags': XrayConfigBuilder.proxyOutboundTags(configJson),
      'metricsPort': XrayConfigBuilder.windowsMetricsPort,
      'socksPort': 10808,
      'httpPort': 10809,
    };
  }

  Future<void> syncQuickSettingsConfig() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      if (_selectedServer == null) {
        await _channel.invokeMethod('clearQuickSettingsConfig');
        return;
      }
      await _channel.invokeMethod(
          'syncQuickSettingsConfig', _selectedServerPayload);
    } catch (_) {}
  }

  String _buildSelectedServerConfig() {
    final ruRouting = StorageService.getRuRouting();
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (isAndroid) {
      return XrayConfigBuilder.buildAndroidVpnConfig(_selectedServer!,
          statsApi: true, enableRuRouting: ruRouting);
    }
    return XrayConfigBuilder.buildSystemProxyConfig(_selectedServer!,
        enableRuRouting: ruRouting);
  }

  /// The Windows runner answers connect/reconnect only after the core, routes
  /// and system proxy are all in place, so one status check right away replaces
  /// waiting for the first one-second poll tick. Android answers as soon as the
  /// service is asked to start, so it keeps relying on the poll.
  Future<bool> _confirmWindowsCoreRunning() async {
    if (!_isWindows) return false;
    try {
      final isRunning = await _channel.invokeMethod<bool>('getStatus');
      if (isRunning == true && _status == VpnStatus.connecting) {
        _markConnected();
        return true;
      }
    } catch (_) {}
    return false;
  }

  void _markConnected() {
    _connectingPollTimer?.cancel();
    _connectedAt = DateTime.now();
    _statusDetail = null;
    _errorMessage = null;
    _setStatus(VpnStatus.connected);
    _startStatsTracking();
    // Attempts count from zero again only once a connection has held for a
    // while, so a core that dies right after every start does not loop forever.
    _stableConnectionTimer?.cancel();
    _stableConnectionTimer = Timer(const Duration(minutes: 1), () {
      _autoReconnectAttempt = 0;
    });
  }

  void _startConnectingPoll() {
    _connectingPollTimer?.cancel();
    int attempts = 0;
    _connectingPollTimer =
        Timer.periodic(const Duration(seconds: 1), (t) async {
      if (_status != VpnStatus.connecting) {
        t.cancel();
        return;
      }
      attempts++;
      if (attempts > 20) {
        t.cancel();
        if (_status == VpnStatus.connecting) {
          _errorMessage = 'Не удалось подключиться. Проверьте разрешения.';
          _setStatus(VpnStatus.error);
        }
        return;
      }
      try {
        final isRunning = await _channel.invokeMethod<bool>('getStatus');
        if (isRunning == true && _status == VpnStatus.connecting) {
          _markConnected();
        }
      } catch (_) {}
    });
  }

  Future<void> disconnect() async {
    _cancelAutoReconnect();
    _statusDetail = null;
    if (!_isVpnSupportedPlatform) {
      _stopStatsTracking();
      _setStatus(VpnStatus.disconnected);
      _stats = const VpnStats();
      notifyListeners();
      return;
    }
    _setStatus(VpnStatus.disconnecting);
    try {
      await _channel.invokeMethod('disconnect');
    } on PlatformException catch (e) {
      debugPrint('Disconnect error: ${e.message}');
    }
    _stopStatsTracking();
    _stats = const VpnStats();
    _errorMessage = null;
    _setStatus(VpnStatus.disconnected);
  }

  // ─── Dropped connections ──────────────────────────────────────────────────

  /// The native side lost a connection nobody asked to stop.
  void _handleCoreStopped(String? message) {
    if (_status != VpnStatus.connected && _status != VpnStatus.connecting) {
      return;
    }
    _connectingPollTimer?.cancel();
    _stopStatsTracking();
    _stats = const VpnStats();
    if (_scheduleAutoReconnect()) return;
    _statusDetail = null;
    _errorMessage = message ?? 'Соединение прервалось';
    _setStatus(VpnStatus.error);
  }

  /// Returns false once the attempts are used up.
  bool _scheduleAutoReconnect() {
    if (_selectedServer == null ||
        _autoReconnectAttempt >= _autoReconnectDelaysSeconds.length) {
      _autoReconnectAttempt = 0;
      return false;
    }
    final delay =
        Duration(seconds: _autoReconnectDelaysSeconds[_autoReconnectAttempt]);
    _autoReconnectAttempt++;
    _autoReconnectTimer?.cancel();
    _stableConnectionTimer?.cancel();
    _errorMessage = null;
    _statusDetail = 'Соединение прервалось, переподключаемся…';
    _setStatus(VpnStatus.connecting);
    _autoReconnectTimer = Timer(delay, () {
      if (_status == VpnStatus.connecting) {
        unawaited(_connect(automatic: true));
      }
    });
    return true;
  }

  void _cancelAutoReconnect() {
    _autoReconnectTimer?.cancel();
    _autoReconnectTimer = null;
    _stableConnectionTimer?.cancel();
    _stableConnectionTimer = null;
    _autoReconnectAttempt = 0;
  }

  // ─── Native status listener ───────────────────────────────────────────────
  void _listenNativeStatus() {
    if (!_isVpnSupportedPlatform) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onConnected':
          _connectedAt = DateTime.now();
          _setStatus(VpnStatus.connected);
          _startStatsTracking();
        case 'onDisconnected':
          _stopStatsTracking();
          _setStatus(VpnStatus.disconnected);
          _stats = const VpnStats();
          notifyListeners();
        case 'onError':
          _stopStatsTracking();
          _errorMessage = call.arguments as String?;
          _setStatus(VpnStatus.error);
        case 'onCoreStopped':
          final details = call.arguments;
          _handleCoreStopped(
            details is Map ? details['error']?.toString() : null,
          );
        case 'trayToggle':
          unawaited(toggleConnection());
      }
    });
  }

  // ─── Tray (Windows) ───────────────────────────────────────────────────────
  Future<void> _updateTray() async {
    if (!_isWindows) return;
    final state = switch (_status) {
      VpnStatus.connected => 'connected',
      VpnStatus.connecting => 'connecting',
      VpnStatus.disconnecting => 'disconnecting',
      VpnStatus.error => 'error',
      VpnStatus.disconnected => 'disconnected',
    };
    try {
      await _channel.invokeMethod('updateTrayStatus', {
        'state': state,
        'server': _selectedServer?.displayName ?? '',
      });
    } catch (_) {}
  }

  // ─── Stats ────────────────────────────────────────────────────────────────
  void _startStatsTracking() {
    // Native "connected" can arrive after the poll already marked the
    // connection up; a second set of timers would double-count the speed.
    _statsSubscription?.cancel();
    _statsSubscription = null;
    _durationTimer?.cancel();

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _statsSubscription =
          _statsChannel.receiveBroadcastStream().listen((data) {
        if (data is Map) {
          final newDownload =
              (data['download'] as int?) ?? _stats.downloadBytes;
          final newUpload = (data['upload'] as int?) ?? _stats.uploadBytes;
          // Только обновляем байты — скорость считает таймер раз в секунду
          _stats = _stats.copyWith(
            downloadBytes: newDownload,
            uploadBytes: newUpload,
          );
          notifyListeners();
        }
      });
    }

    // Таймер для обновления времени каждую секунду (+ опрос статистики на Windows)
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_connectedAt != null) {
        final duration = DateTime.now().difference(_connectedAt!);
        if (_isWindows) {
          unawaited(_pollWindowsStats(duration));
        } else {
          // Android: байты уже обновляются через EventChannel, здесь считаем скорость
          final dlSpeed =
              (_stats.downloadBytes - _prevDownloadBytes).clamp(0, 1 << 30);
          final ulSpeed =
              (_stats.uploadBytes - _prevUploadBytes).clamp(0, 1 << 30);
          _prevDownloadBytes = _stats.downloadBytes;
          _prevUploadBytes = _stats.uploadBytes;
          _stats = _stats.copyWith(
            connectedDuration: duration,
            downloadSpeed: _smoothSpeedSample(
              dlSpeed,
              _downloadSpeedSamples,
            ),
            uploadSpeed: _smoothSpeedSample(
              ulSpeed,
              _uploadSpeedSamples,
            ),
          );
          notifyListeners();
        }
      }
    });
  }

  Future<void> _pollWindowsStats(Duration duration) async {
    try {
      final result =
          await _channel.invokeMethod<Map<Object?, Object?>>('getStats');
      if (result == null) return;
      final newDownload = (result['download'] as int?) ?? _stats.downloadBytes;
      final newUpload = (result['upload'] as int?) ?? _stats.uploadBytes;
      // Таймер вызывается раз в секунду — разница байт = скорость в байт/с
      final dlSpeed = (newDownload - _prevDownloadBytes).clamp(0, 1 << 30);
      final ulSpeed = (newUpload - _prevUploadBytes).clamp(0, 1 << 30);
      _prevDownloadBytes = newDownload;
      _prevUploadBytes = newUpload;
      _stats = VpnStats(
        downloadBytes: newDownload,
        uploadBytes: newUpload,
        connectedDuration: duration,
        downloadSpeed: _smoothSpeedSample(
          dlSpeed,
          _downloadSpeedSamples,
        ),
        uploadSpeed: _smoothSpeedSample(
          ulSpeed,
          _uploadSpeedSamples,
        ),
      );
      notifyListeners();
    } catch (_) {
      _stats = _stats.copyWith(connectedDuration: duration);
      notifyListeners();
    }
  }

  void _stopStatsTracking() {
    _statsSubscription?.cancel();
    _statsSubscription = null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _connectingPollTimer?.cancel();
    _connectingPollTimer = null;
    _connectedAt = null;
    _prevDownloadBytes = 0;
    _prevUploadBytes = 0;
    _downloadSpeedSamples.clear();
    _uploadSpeedSamples.clear();
  }

  int _smoothSpeedSample(int speed, ListQueue<int> samples) {
    samples.addLast(speed);
    while (samples.length > 4) {
      samples.removeFirst();
    }

    final total = samples.fold<int>(0, (sum, value) => sum + value);
    final average = (total / samples.length).round();

    // Не держим призрачную скорость, если трафик реально почти исчез.
    if (speed == 0 && average < 64) {
      return 0;
    }

    return average;
  }

  void _setStatus(VpnStatus status) {
    final changed = _status != status;
    _status = status;
    notifyListeners();
    if (changed) unawaited(_updateTray());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelAutoReconnect();
    _stopStatsTracking();
    super.dispose();
  }
}
