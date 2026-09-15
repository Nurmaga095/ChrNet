import 'package:chrnet/core/models/server_config.dart';
import 'package:chrnet/core/services/device_service.dart';
import 'package:chrnet/core/services/import_service.dart';
import 'package:flutter_test/flutter_test.dart';

ServerConfig _config({required String host, String uuid = 'real-uuid'}) {
  return ServerConfig(
    id: 'id-$host',
    name: 'server',
    host: host,
    port: host == '0.0.0.0' ? 1 : 443,
    protocol: 'json',
    uuid: uuid,
    rawUri: '{}',
    extras: const {},
    addedAt: DateTime(2026),
  );
}

void main() {
  group('HWID-заглушка подписки', () {
    final placeholder = _config(
      host: '0.0.0.0',
      uuid: '00000000-0000-0000-0000-000000000000',
    );
    final real = _config(host: 'example.com');

    test('заглушка распознаётся по адресу 0.0.0.0 без заголовков', () {
      expect(ImportService.hwidRejection(const {}, [placeholder]), isNotNull);
    });

    test('заглушка распознаётся по заголовку панели', () {
      final message = ImportService.hwidRejection(
        const {'x-hwid-not-supported': 'true'},
        [real],
      );
      expect(message, isNotNull);
      expect(message, contains('HWID'));
    });

    test('лимит устройств сообщается отдельным текстом', () {
      final message = ImportService.hwidRejection(
        const {'x-hwid-limit-reached': 'true'},
        [real],
      );
      expect(message, contains('лимит'));
    });

    test('рабочая подписка проходит', () {
      expect(
        ImportService.hwidRejection(const {'x-hwid-active': 'true'}, [real]),
        isNull,
      );
    });

    test('один нерабочий сервер среди рабочих не считается заглушкой', () {
      expect(
        ImportService.hwidRejection(const {}, [placeholder, real]),
        isNull,
      );
    });
  });

  group('Заголовки устройства', () {
    test('x-hwid отправляется всегда', () {
      const info = DeviceInfo(
        deviceId: '75af4feb-e65e-4136-8ce3-8e7220019b31',
        platform: 'Windows',
        osVersion: '10.0.26200',
        model: 'Windows PC',
        appVersion: '2.0.0',
      );

      final headers = info.subscriptionHeaders;
      expect(headers['x-hwid'], isNotEmpty);
      expect(headers['x-device-os'], 'Windows');
      expect(headers['x-ver-os'], '10.0.26200');
      expect(headers['User-Agent'], 'ChrNet/2.0.0 (Windows)');
    });
  });
}
