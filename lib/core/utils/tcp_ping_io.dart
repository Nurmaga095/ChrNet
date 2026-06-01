import 'dart:async';
import 'dart:io';

import '../models/server_config.dart';
import '../services/xray_config_builder.dart';

Future<int?> measureProxyHttpPing(
  ServerConfig server, {
  required Uri testUri,
  required String method,
}) async {
  if (testUri.scheme != 'http' && testUri.scheme != 'https') {
    return null;
  }

  final xrayPath = _resolveXrayPath();
  if (xrayPath == null) {
    return null;
  }

  final port = await _reserveLocalPort();
  if (port == null) {
    return null;
  }

  final tempDir = await Directory.systemTemp.createTemp('chrnet_ping_');
  final configPath = '${tempDir.path}${Platform.pathSeparator}xray.json';
  Process? process;

  try {
    final configJson = XrayConfigBuilder.buildHttpPingProxyConfig(
      server,
      httpPort: port,
    );
    await File(configPath).writeAsString(configJson);

    process = await Process.start(
      xrayPath,
      ['run', '-c', configPath],
      workingDirectory: File(xrayPath).parent.path,
      mode: ProcessStartMode.normal,
    );
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final ready = await _waitForLocalPort(port);
    if (!ready) {
      return null;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 15)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      final normalizedMethod = method.toUpperCase() == 'HEAD' ? 'HEAD' : 'GET';
      int? warmupPing;
      final samples = <int>[];

      for (var attempt = 0; attempt < 4; attempt++) {
        final ping = await _measureProxyHttpSample(
          client,
          testUri,
          method: normalizedMethod,
        );
        if (ping != null) {
          if (warmupPing == null) {
            warmupPing = ping;
          } else {
            samples.add(ping);
          }
        }

        if (attempt < 3) {
          await Future.delayed(const Duration(milliseconds: 120));
        }
      }

      if (samples.isEmpty) {
        return warmupPing;
      }
      samples.sort();
      return samples.first;
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    return null;
  } finally {
    process?.kill();
    try {
      await process?.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

Future<int?> _measureProxyHttpSample(
  HttpClient client,
  Uri testUri, {
  required String method,
}) async {
  final sw = Stopwatch()..start();
  try {
    final request = await client.openUrl(method, testUri).timeout(
          const Duration(seconds: 8),
        );
    request.followRedirects = false;
    request.headers.set('Cache-Control', 'no-cache');
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>().timeout(const Duration(seconds: 8));
    sw.stop();
    final statusCode = response.statusCode;
    if (statusCode < 200 || statusCode >= 500) {
      return null;
    }
    return sw.elapsedMilliseconds <= 0 ? 1 : sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}

Future<int?> measureIcmpPing(String host) async {
  final normalizedHost = host.trim();
  if (normalizedHost.isEmpty) {
    return null;
  }

  final args = Platform.isWindows
      ? <String>['-n', '1', '-w', '2000', normalizedHost]
      : <String>['-c', '1', '-W', '2', normalizedHost];

  try {
    final result = await Process.run(
      'ping',
      args,
      runInShell: Platform.isWindows,
    ).timeout(const Duration(seconds: 3));
    final output = '${result.stdout}\n${result.stderr}';
    return _parsePingOutput(output);
  } catch (_) {
    return null;
  }
}

Future<int?> measureTcpPing(String host, int port) async {
  final normalizedHost = host.trim();
  if (normalizedHost.isEmpty || port <= 0 || port > 65535) {
    return null;
  }

  const sampleWindow = Duration(seconds: 2);
  const pauseBetweenAttempts = Duration(milliseconds: 120);
  final deadline = DateTime.now().add(sampleWindow);
  final samples = <int>[];

  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      break;
    }

    final ping = await _measureSingleTcpPing(
      normalizedHost,
      port,
      timeout: remaining,
    );
    if (ping != null) {
      samples.add(ping);
    }

    final restAfterAttempt = deadline.difference(DateTime.now());
    if (restAfterAttempt <= Duration.zero) {
      break;
    }

    final pause = restAfterAttempt < pauseBetweenAttempts
        ? restAfterAttempt
        : pauseBetweenAttempts;
    await Future.delayed(pause);
  }

  if (samples.isEmpty) {
    return null;
  }

  samples.sort();
  return samples[samples.length ~/ 2];
}

Future<int?> _measureSingleTcpPing(
  String host,
  int port, {
  required Duration timeout,
}) async {
  final sw = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      timeout: timeout,
    ).timeout(timeout);
    sw.stop();
    final ms = sw.elapsedMilliseconds;
    return ms <= 0 ? 1 : ms;
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}

Future<int?> _reserveLocalPort() async {
  ServerSocket? socket;
  try {
    socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return socket.port;
  } catch (_) {
    return null;
  } finally {
    await socket?.close();
  }
}

Future<bool> _waitForLocalPort(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 250),
      );
      return true;
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 100));
    } finally {
      socket?.destroy();
    }
  }
  return false;
}

String? _resolveXrayPath() {
  final envPath = Platform.environment['CHRNET_XRAY_PATH']?.trim();
  if (envPath != null && envPath.isNotEmpty && File(envPath).existsSync()) {
    return envPath;
  }

  final candidates = <String>[
    '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}xray.exe',
    '${Directory.current.path}${Platform.pathSeparator}xray.exe',
    '${Directory.current.path}${Platform.pathSeparator}tools${Platform.pathSeparator}xray${Platform.pathSeparator}dist${Platform.pathSeparator}xray.exe',
    '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}windows${Platform.pathSeparator}x64${Platform.pathSeparator}runner${Platform.pathSeparator}Release${Platform.pathSeparator}xray.exe',
  ];

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }

  return null;
}

int? _parsePingOutput(String output) {
  final timeMatch = RegExp(
    r'(?:time|время)\s*[=<]\s*([0-9]+(?:[,.][0-9]+)?)\s*(?:ms|мс)',
    caseSensitive: false,
  ).firstMatch(output);
  if (timeMatch != null) {
    return _parsePingMs(timeMatch.group(1));
  }

  final averageMatch = RegExp(
    r'(?:avg|average|сред[^\s=]*)\s*[=/]\s*([0-9]+(?:[,.][0-9]+)?)',
    caseSensitive: false,
  ).firstMatch(output);
  if (averageMatch != null) {
    return _parsePingMs(averageMatch.group(1));
  }

  return null;
}

int? _parsePingMs(String? value) {
  if (value == null) return null;
  final parsed = double.tryParse(value.replaceAll(',', '.'));
  if (parsed == null) return null;
  final rounded = parsed.round();
  return rounded <= 0 ? 1 : rounded;
}
