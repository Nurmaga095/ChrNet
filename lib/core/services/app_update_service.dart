import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_info_service.dart';

class AppUpdateService {
  static const _latestWindowsInstallerUrl =
      'https://github.com/Nurmaga095/ChrNet/releases/latest/download/ChrNet-Setup-latest.exe';
  static const _downloadTimeout = Duration(minutes: 5);

  static bool get isWindowsSelfUpdateSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static Future<File> downloadLatestWindowsInstaller({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    if (!isWindowsSelfUpdateSupported) {
      throw UnsupportedError('Self-update is only supported on Windows.');
    }

    final client = http.Client();
    final userAgent = 'ChrNet/${await AppInfoService.getVersion()}';

    try {
      final request = http.Request('GET', Uri.parse(_latestWindowsInstallerUrl))
        ..headers.addAll({
          'Accept': 'application/octet-stream',
          'User-Agent': userAgent,
        });

      final response = await client.send(request).timeout(_downloadTimeout);
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to download installer: HTTP ${response.statusCode}',
        );
      }

      final tempDir = await Directory.systemTemp.createTemp('chrnet_update_');
      final safeVersion = targetVersion.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
      final installerFile =
          File('${tempDir.path}${Platform.pathSeparator}ChrNet-Setup-$safeVersion.exe');
      final sink = installerFile.openWrite();

      try {
        final totalBytes = response.contentLength;
        var receivedBytes = 0;

        await for (final chunk in response.stream.timeout(_downloadTimeout)) {
          sink.add(chunk);
          receivedBytes += chunk.length;

          if (totalBytes != null && totalBytes > 0) {
            onProgress?.call(receivedBytes / totalBytes);
          }
        }
      } finally {
        await sink.close();
      }

      onProgress?.call(1);
      return installerFile;
    } finally {
      client.close();
    }
  }

  static Future<void> launchInstaller(File installerFile) async {
    if (!isWindowsSelfUpdateSupported) {
      throw UnsupportedError('Installer launch is only supported on Windows.');
    }

    await Process.start(
      installerFile.path,
      const [],
      mode: ProcessStartMode.detached,
      workingDirectory: installerFile.parent.path,
    );
  }
}
