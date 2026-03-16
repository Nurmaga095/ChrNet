import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class AppInfoService {
  static String? _cachedVersion;
  static String? _cachedLatestGithubVersion;
  static const _latestReleaseUrl =
      'https://api.github.com/repos/Nurmaga095/ChrNet/releases/latest';
  static const _releasesListUrl =
      'https://api.github.com/repos/Nurmaga095/ChrNet/releases?per_page=1';
  static const _latestReleasePageUrl =
      'https://github.com/Nurmaga095/ChrNet/releases/latest';
  static const _requestTimeout = Duration(seconds: 10);

  static Future<String> getVersion() async {
    if (_cachedVersion != null) {
      return _cachedVersion!;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version.trim();
      _cachedVersion = version.isEmpty || version.toLowerCase() == 'unknown'
          ? 'unknown'
          : version;
    } catch (_) {
      _cachedVersion = 'unknown';
    }

    return _cachedVersion!;
  }

  static Future<String?> getLatestGithubVersion({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedLatestGithubVersion != null) {
      return _cachedLatestGithubVersion;
    }

    final userAgent = 'ChrNet/${await getVersion()}';
    final client = http.Client();

    try {
      final latestVersion =
          await _fetchLatestVersionFromApi(client, userAgent) ??
          await _fetchLatestVersionFromList(client, userAgent) ??
          await _fetchLatestVersionFromRedirect(client, userAgent);

      if (latestVersion == null || latestVersion.isEmpty) {
        return null;
      }

      _cachedLatestGithubVersion = latestVersion;
      return latestVersion;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static Future<String?> _fetchLatestVersionFromApi(
    http.Client client,
    String userAgent,
  ) async {
    final response = await client
        .get(
          Uri.parse(_latestReleaseUrl),
          headers: _buildGithubHeaders(userAgent),
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      return null;
    }

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      return null;
    }

    return _normalizeGithubTag(body['tag_name'] as String?);
  }

  static Future<String?> _fetchLatestVersionFromList(
    http.Client client,
    String userAgent,
  ) async {
    final response = await client
        .get(
          Uri.parse(_releasesListUrl),
          headers: _buildGithubHeaders(userAgent),
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      return null;
    }

    final body = jsonDecode(response.body);
    if (body is! List) {
      return null;
    }

    for (final item in body) {
      if (item is! Map<String, dynamic>) {
        continue;
      }

      if ((item['draft'] as bool?) ?? false) {
        continue;
      }

      return _normalizeGithubTag(item['tag_name'] as String?);
    }

    return null;
  }

  static Future<String?> _fetchLatestVersionFromRedirect(
    http.Client client,
    String userAgent,
  ) async {
    final request = http.Request('GET', Uri.parse(_latestReleasePageUrl))
      ..followRedirects = false
      ..headers.addAll({
        'Accept': 'text/html,application/xhtml+xml',
        'User-Agent': userAgent,
      });

    final response = await client.send(request).timeout(_requestTimeout);
    final location = response.headers['location'];
    if (location == null || location.isEmpty) {
      return null;
    }

    final match = RegExp(r'/tag/v([^/?#]+)$').firstMatch(location);
    if (match == null) {
      return null;
    }

    return _normalizeGithubTag(match.group(1));
  }

  static Map<String, String> _buildGithubHeaders(String userAgent) {
    return {
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': userAgent,
    };
  }

  static String? _normalizeGithubTag(String? rawTag) {
    final trimmed = rawTag?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }

    return trimmed.replaceFirst(RegExp(r'^v'), '');
  }

  static int compareVersions(String currentVersion, String otherVersion) {
    final currentParts = _extractVersionParts(currentVersion);
    final otherParts = _extractVersionParts(otherVersion);
    final maxLength = currentParts.length > otherParts.length
        ? currentParts.length
        : otherParts.length;

    for (var index = 0; index < maxLength; index++) {
      final currentPart = index < currentParts.length ? currentParts[index] : 0;
      final otherPart = index < otherParts.length ? otherParts[index] : 0;

      if (currentPart != otherPart) {
        return currentPart.compareTo(otherPart);
      }
    }

    return 0;
  }

  static List<int> _extractVersionParts(String version) {
    final matches = RegExp(r'\d+').allMatches(version);
    return matches.map((match) => int.parse(match.group(0)!)).toList();
  }
}
