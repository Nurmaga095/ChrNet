class VpnStats {
  final int downloadBytes;
  final int uploadBytes;
  final Duration connectedDuration;
  final int downloadSpeed; // bytes per second
  final int uploadSpeed;   // bytes per second

  const VpnStats({
    this.downloadBytes = 0,
    this.uploadBytes = 0,
    this.connectedDuration = Duration.zero,
    this.downloadSpeed = 0,
    this.uploadSpeed = 0,
  });

  VpnStats copyWith({
    int? downloadBytes,
    int? uploadBytes,
    Duration? connectedDuration,
    int? downloadSpeed,
    int? uploadSpeed,
  }) {
    return VpnStats(
      downloadBytes: downloadBytes ?? this.downloadBytes,
      uploadBytes: uploadBytes ?? this.uploadBytes,
      connectedDuration: connectedDuration ?? this.connectedDuration,
      downloadSpeed: downloadSpeed ?? this.downloadSpeed,
      uploadSpeed: uploadSpeed ?? this.uploadSpeed,
    );
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 Б';
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГБ';
  }

  static String formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 Б/с';
    if (bytesPerSecond < 1024) return '$bytesPerSecond Б/с';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} КБ/с';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} МБ/с';
  }

  String get downloadFormatted => formatBytes(downloadBytes);
  String get uploadFormatted => formatBytes(uploadBytes);
  String get downloadSpeedFormatted => formatSpeed(downloadSpeed);
  String get uploadSpeedFormatted => formatSpeed(uploadSpeed);

  String get durationFormatted {
    final h = connectedDuration.inHours;
    final m = connectedDuration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = connectedDuration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }
}

enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

extension VpnStatusLabel on VpnStatus {
  String get label {
    switch (this) {
      case VpnStatus.disconnected:
        return 'VPN выключен';
      case VpnStatus.connecting:
        return 'Подключение...';
      case VpnStatus.connected:
        return 'VPN включён';
      case VpnStatus.disconnecting:
        return 'Отключение...';
      case VpnStatus.error:
        return 'Ошибка подключения';
    }
  }

  bool get isActive =>
      this == VpnStatus.connected || this == VpnStatus.connecting;
}
