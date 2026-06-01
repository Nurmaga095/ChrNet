import '../models/server_config.dart';
import '../models/subscription.dart';
import 'import_service.dart';
import 'storage_service.dart';

class SubscriptionRefreshResult {
  final bool success;
  final String? error;
  final Subscription subscription;
  final List<ServerConfig> servers;
  final ServerConfig? replacementSelectedServer;

  const SubscriptionRefreshResult({
    required this.success,
    required this.subscription,
    this.error,
    this.servers = const [],
    this.replacementSelectedServer,
  });
}

class SubscriptionService {
  static Future<SubscriptionRefreshResult> refreshSubscription(
    Subscription subscription,
  ) async {
    var nextSubscription = subscription;
    final result =
        await ImportService.importFromSubscriptionUrl(subscription.url);
    if (result.result != ImportResult.success) {
      return SubscriptionRefreshResult(
        success: false,
        subscription: nextSubscription,
        error: result.error ?? 'Ошибка обновления подписки',
      );
    }

    final oldServers = StorageService.getServers()
        .where((server) => server.subscriptionId == subscription.id)
        .toList();
    final oldServersByRawUri = {
      for (final server in oldServers) server.rawUri: server,
    };

    final selectedServerId = StorageService.getSelectedServerId();
    final selectedServerBelongsToSubscription = oldServers.any(
      (server) => server.id == selectedServerId,
    );

    final nextServers = result.configs.map((server) {
      final previous = oldServersByRawUri[server.rawUri];
      final next = previous != null
          ? server.copyWith(
              id: previous.id,
              addedAt: previous.addedAt,
              subscriptionOrder: server.subscriptionOrder,
              subscriptionId: subscription.id,
            )
          : server.copyWith(subscriptionId: subscription.id);
      return next;
    }).toList();

    for (final server in oldServers) {
      await StorageService.deleteServer(server.id);
    }
    await StorageService.saveServers(nextServers);

    if (result.subscriptionUrl != null) {
      nextSubscription =
          nextSubscription.copyWith(url: result.subscriptionUrl!);
    }
    nextSubscription.lastUpdated = DateTime.now();
    nextSubscription.serverCount = nextServers.length;
    nextSubscription.dnsServers = result.dnsServers;
    if (result.profileTitle != null) {
      nextSubscription.name = result.profileTitle!;
    }
    if (result.uploadBytes != null) {
      nextSubscription.uploadBytes = result.uploadBytes;
    }
    if (result.downloadBytes != null) {
      nextSubscription.downloadBytes = result.downloadBytes;
    }
    if (result.totalBytes != null) {
      nextSubscription.totalBytes = result.totalBytes;
    }
    if (result.expireTimestamp != null) {
      nextSubscription.expireTimestamp = result.expireTimestamp;
    }
    nextSubscription.description = result.description;
    await StorageService.saveSubscription(nextSubscription);

    final selectedServerStillExists = selectedServerId != null &&
        nextServers.any((server) => server.id == selectedServerId);
    final replacementSelectedServer = selectedServerBelongsToSubscription &&
            !selectedServerStillExists &&
            nextServers.isNotEmpty
        ? nextServers.first
        : null;

    return SubscriptionRefreshResult(
      success: true,
      subscription: nextSubscription,
      servers: nextServers,
      replacementSelectedServer: replacementSelectedServer,
    );
  }
}
