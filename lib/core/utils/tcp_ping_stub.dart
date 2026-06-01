import '../models/server_config.dart';

Future<int?> measureIcmpPing(String host) async => null;

Future<int?> measureTcpPing(String host, int port) async => null;

Future<int?> measureProxyHttpPing(
  ServerConfig server, {
  required Uri testUri,
  required String method,
}) async =>
    null;
