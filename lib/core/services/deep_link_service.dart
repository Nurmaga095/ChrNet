import 'dart:async';
import 'package:flutter/services.dart';

/// Handles `chrnet://add/<subscription_url>` deep links.
///
/// On Windows the URL is passed as a CLI argument.
/// On Android it arrives via a MethodChannel call from MainActivity.
class DeepLinkService {
  DeepLinkService._();

  static const _channel = MethodChannel('com.chrnet.vpn/deep_link');

  static String? _pendingUrl;
  static final _controller = StreamController<String>.broadcast();

  /// Stream that emits subscription URLs as they arrive (including when
  /// the app is already running and a deep link opens via onNewIntent).
  static Stream<String> get urlStream => _controller.stream;

  /// Call once at startup with the CLI arguments (Windows only).
  static void initFromArgs(List<String> args) {
    for (final arg in args) {
      final url = _extractUrl(arg);
      if (url != null) {
        _pendingUrl = url;
        break;
      }
    }
  }

  /// Register the Android MethodChannel handler (call from main()).
  static void initChannel() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink') {
        final url = _extractUrl(call.arguments as String? ?? '');
        if (url != null) {
          _pendingUrl = url;
          _controller.add(url);
        }
      }
    });
  }

  /// Returns and clears the pending subscription URL (if any).
  static String? consumePendingUrl() {
    final url = _pendingUrl;
    _pendingUrl = null;
    return url;
  }

  static String? _extractUrl(String raw) {
    const scheme = 'chrnet://add/';
    if (raw.toLowerCase().startsWith(scheme)) {
      final payload = raw.substring(scheme.length);
      if (payload.isNotEmpty) return Uri.decodeFull(payload);
    }
    return null;
  }
}
