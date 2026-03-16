import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../models/server_config.dart';
import '../models/vpn_stats.dart';
import 'storage_service.dart';
import 'xray_config_builder.dart';

class VpnProvider extends ChangeNotifier with WidgetsBindingObserver {
  // ─── Platform channel для нативного Xray ─────────────────────────────────
  static const _channel = MethodChannel('com.chrnet.vpn/service');
  static const _statsChannel = EventChannel('com.chrnet.vpn/stats');

  VpnStatus _status = VpnStatus.disconnected;
  VpnStats _stats = const VpnStats();
  ServerConfig? _selectedServer;
  String? _errorMessage;
  StreamSubscription? _statsSubscription;
  Timer? _durationTimer;
  Timer? _connectingPollTimer;
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
  bool get isConnected => _status == VpnStatus.connected;
  bool get isConnecting => _status == VpnStatus.connecting;
  bool get _isVpnSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.iOS);

  VpnProvider() {
    _loadSelectedServer();
    _listenNativeStatus();
    _syncStatusWithNative();
    unawaited(syncQuickSettingsConfig());
    WidgetsBinding.instance.addObserver(this);
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
      final isRunning = await _channel.invokeMethod<bool>('getStatus');
      if (isRunning == true && _status == VpnStatus.disconnected) {
        _connectedAt = DateTime.now();
        _setStatus(VpnStatus.connected);
        _startStatsTracking();
      } else if (isRunning != true && _status == VpnStatus.connected) {
        _stopStatsTracking();
        _setStatus(VpnStatus.disconnected);
        _stats = const VpnStats();
        notifyListeners();
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

  Future<void> connect() async {
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

    _setStatus(VpnStatus.connecting);
    _errorMessage = null;

    try {
      await syncQuickSettingsConfig();
      await _channel.invokeMethod('connect', _selectedServerPayload);
      // Polling: раз в секунду спрашиваем у сервиса — вдруг push не дошёл
      _startConnectingPoll();
    } on MissingPluginException {
      _errorMessage = 'VPN-сервис недоступен';
      _setStatus(VpnStatus.error);
    } on PlatformException catch (e) {
      _errorMessage = e.message ?? 'Ошибка подключения';
      _setStatus(VpnStatus.error);
    } catch (e) {
      _errorMessage = 'Ошибка подключения: $e';
      _setStatus(VpnStatus.error);
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

    _stopStatsTracking();
    _stats = const VpnStats();
    _setStatus(VpnStatus.connecting);
    _errorMessage = null;

    try {
      await syncQuickSettingsConfig();
      await _channel.invokeMethod('reconnect', _selectedServerPayload);
      _startConnectingPoll();
    } on MissingPluginException {
      _errorMessage = 'VPN-сервис недоступен';
      _setStatus(VpnStatus.error);
    } on PlatformException catch (e) {
      _errorMessage = e.message ?? 'Ошибка переподключения';
      _setStatus(VpnStatus.error);
    } catch (e) {
      _errorMessage = 'Ошибка переподключения: $e';
      _setStatus(VpnStatus.error);
    }
  }

  Map<String, dynamic> get _selectedServerPayload => {
        'rawUri': _selectedServer!.rawUri,
        'configJson': _buildSelectedServerConfig(),
        'ruRouting': StorageService.getRuRouting(),
        'serverName': _selectedServer!.displayName,
        'windowsMode': StorageService.getWindowsVpnMode(),
        'host': _selectedServer!.host,
        'port': _selectedServer!.port,
        'protocol': _selectedServer!.protocol,
        'uuid': _selectedServer!.uuid,
        'extras': _selectedServer!.extras,
      };

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
    final mode = StorageService.getWindowsVpnMode();
    final ruRouting = StorageService.getRuRouting();
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    if (isWindows && mode == 'tunnel') {
      return XrayConfigBuilder.buildTunnelConfig(_selectedServer!,
          statsApi: true, enableRuRouting: ruRouting);
    }
    return XrayConfigBuilder.buildSystemProxyConfig(_selectedServer!,
        statsApi: isWindows, enableRuRouting: ruRouting);
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
          t.cancel();
          _connectedAt = DateTime.now();
          _setStatus(VpnStatus.connected);
          _startStatsTracking();
        }
      } catch (_) {}
    });
  }

  Future<void> disconnect() async {
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
    _setStatus(VpnStatus.disconnected);
    _stats = const VpnStats();
    notifyListeners();
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
      }
    });
  }

  // ─── Stats ────────────────────────────────────────────────────────────────
  void _startStatsTracking() {
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
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
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
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStatsTracking();
    super.dispose();
  }
}
