/// Name resolution needs dart:io; without it nothing gets pinned.
Future<Map<String, List<String>>> resolveIpv4Addresses(
  Iterable<String> hosts, {
  Duration timeout = const Duration(seconds: 4),
}) async =>
    const {};
