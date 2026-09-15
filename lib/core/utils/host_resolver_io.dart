import 'dart:async';
import 'dart:io';

/// Resolves every host name in [hosts] to its IPv4 addresses through the
/// system resolver. IP literals and names that fail to resolve are left out;
/// the native side resolves whatever is missing on its own.
Future<Map<String, List<String>>> resolveIpv4Addresses(
  Iterable<String> hosts, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final result = <String, List<String>>{};
  await Future.wait(hosts.map((host) => host.trim()).toSet().map((name) async {
    if (name.isEmpty || InternetAddress.tryParse(name) != null) return;
    try {
      final addresses = await InternetAddress.lookup(
        name,
        type: InternetAddressType.IPv4,
      ).timeout(timeout);
      final ips = {for (final address in addresses) address.address}.toList();
      if (ips.isNotEmpty) result[name] = ips;
    } catch (_) {}
  }));
  return result;
}
