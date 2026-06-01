import 'dart:io';

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
