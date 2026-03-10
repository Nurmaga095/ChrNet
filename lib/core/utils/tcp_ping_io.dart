import 'dart:io';

Future<int?> measureTcpPing(String host, int port) async {
  final sw = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
    sw.stop();
    final ms = sw.elapsedMilliseconds;
    return ms <= 0 ? 1 : ms;
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}
