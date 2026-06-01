import 'dart:io';

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
