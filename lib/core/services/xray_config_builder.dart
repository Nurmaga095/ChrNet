import 'dart:convert';

import '../models/server_config.dart';
import 'storage_service.dart';

class XrayConfigBuilder {
  const XrayConfigBuilder._();
  static const List<String> _fallbackDnsServers = ['1.1.1.1', '8.8.8.8'];
  static const List<String> _ruDirectDomainRules = [
    r'regexp:(^|.*\.)ru$',
    r'regexp:(^|.*\.)su$',
    r'regexp:(^|.*\.)xn--p1ai$',
  ];
  static const List<String> _ruDirectIpRules = ['geoip:ru'];

  static String buildProxyConfig(ServerConfig server) {
    return buildSystemProxyConfig(server);
  }

  static String buildHttpPingProxyConfig(
    ServerConfig server, {
    required int httpPort,
  }) {
    final sourceOutbound = _isJsonServer(server)
        ? _normalizeOutbounds(_parseImportedConfig(server)['outbounds'])
            .firstWhere(
            _isProxyOutboundWithEndpoint,
            orElse: () => throw const FormatException(
              'JSON config has no proxy outbound',
            ),
          )
        : _buildOutbound(server);
    final outbound = Map<String, dynamic>.from(sourceOutbound);
    outbound['tag'] = 'proxy';

    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{'servers': _resolveDnsServers(server)},
      'inbounds': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'http-ping-in',
          'listen': '127.0.0.1',
          'port': httpPort,
          'protocol': 'http',
          'settings': <String, dynamic>{},
        },
      ],
      'outbounds': <Map<String, dynamic>>[
        outbound,
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            'ip': <String>[
              '127.0.0.0/8',
              '10.0.0.0/8',
              '172.16.0.0/12',
              '192.168.0.0/16',
            ],
          },
        ],
      },
    };

    return jsonEncode(config);
  }

  static String buildSystemProxyConfig(
    ServerConfig server, {
    bool statsApi = false,
    bool enableRuRouting = true,
  }) {
    if (_isJsonServer(server)) {
      return _buildImportedJsonConfig(
        server,
        tunnelMode: false,
        statsApi: statsApi,
        enableRuRouting: enableRuRouting,
      );
    }

    final outbound = _buildOutbound(server);
    final dnsServers = _resolveDnsServers(server);
    final inbounds = <Map<String, dynamic>>[
      <String, dynamic>{
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'port': 10808,
        'protocol': 'socks',
        'settings': <String, dynamic>{'udp': true},
        'sniffing': <String, dynamic>{
          'enabled': true,
          'destOverride': <String>['http', 'tls'],
        },
      },
      <String, dynamic>{
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'port': 10809,
        'protocol': 'http',
        'settings': <String, dynamic>{},
      },
      if (statsApi) _statsApiInbound(),
    ];
    final routingRules = <Map<String, dynamic>>[
      if (statsApi) _statsApiRoutingRule(),
      <String, dynamic>{
        'type': 'field',
        'outboundTag': 'direct',
        'ip': <String>[
          '127.0.0.0/8',
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
        ],
      },
      if (enableRuRouting) ..._buildRuDirectRoutingRules(),
    ];
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{'servers': dnsServers},
      'inbounds': inbounds,
      'outbounds': <Map<String, dynamic>>[
        outbound,
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': routingRules,
      },
    };
    if (statsApi) {
      config['stats'] = <String, dynamic>{};
      config['api'] = <String, dynamic>{
        'tag': 'api',
        'services': <String>['StatsService'],
      };
      config['policy'] = <String, dynamic>{
        'system': <String, dynamic>{
          'statsOutboundDownlink': true,
          'statsOutboundUplink': true,
        },
      };
    }
    return jsonEncode(config);
  }

  static String buildTunnelConfig(
    ServerConfig server, {
    bool statsApi = false,
    bool enableRuRouting = true,
  }) {
    if (_isJsonServer(server)) {
      return _buildImportedJsonConfig(
        server,
        tunnelMode: true,
        statsApi: statsApi,
        enableRuRouting: enableRuRouting,
      );
    }

    final outbound = _buildOutbound(server);
    final dnsServers = _resolveDnsServers(server);
    final isIp =
        RegExp(r'^[\d.]+$').hasMatch(server.host) || server.host.contains(':');
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{'servers': dnsServers},
      'inbounds': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'tun-in',
          'port': 0,
          'protocol': 'tun',
          'settings': <String, dynamic>{
            'name': 'chrnet0',
            'MTU': 1500,
            'userLevel': 8,
            'address': <String>['10.0.0.1/24'],
            'autoRoute': true,
            'strictRoute': false,
          },
        },
        if (statsApi) _statsApiInbound(),
      ],
      'outbounds': <Map<String, dynamic>>[
        outbound,
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': <Map<String, dynamic>>[
          if (statsApi) _statsApiRoutingRule(),
          // Proxy server goes direct — avoids TUN routing loop
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            if (isIp)
              'ip': <String>[server.host]
            else
              'domain': <String>[server.host],
          },
          // Local networks bypass TUN
          <String, dynamic>{
            'type': 'field',
            'inboundTag': <String>['tun-in'],
            'ip': <String>[
              '127.0.0.0/8',
              '10.0.0.0/8',
              '172.16.0.0/12',
              '192.168.0.0/16',
            ],
            'outboundTag': 'direct',
          },
          if (enableRuRouting)
            ..._buildRuDirectRoutingRules(inboundTag: 'tun-in'),
          // All other traffic through proxy
          <String, dynamic>{
            'type': 'field',
            'inboundTag': <String>['tun-in'],
            'outboundTag': 'proxy',
          },
        ],
      },
    };
    if (statsApi) {
      config['stats'] = <String, dynamic>{};
      config['api'] = <String, dynamic>{
        'tag': 'api',
        'services': <String>['StatsService'],
      };
      config['policy'] = <String, dynamic>{
        'system': <String, dynamic>{
          'statsOutboundDownlink': true,
          'statsOutboundUplink': true,
        },
      };
    }
    return jsonEncode(config);
  }

  static String buildAndroidVpnConfig(
    ServerConfig server, {
    bool statsApi = false,
    bool enableRuRouting = true,
  }) {
    final decoded = jsonDecode(buildTunnelConfig(
      server,
      statsApi: statsApi,
      enableRuRouting: enableRuRouting,
    ));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Tunnel config must be an object');
    }

    final config = Map<String, dynamic>.from(decoded);
    final inbounds = config['inbounds'];
    if (inbounds is List) {
      for (final inbound in inbounds.whereType<Map>()) {
        if ((inbound['protocol']?.toString() ?? '') != 'tun') continue;
        inbound['tag'] = 'tun';
        inbound['settings'] = <String, dynamic>{
          'name': 'xray0',
          'MTU': 1500,
          'userLevel': 8,
        };
        inbound['sniffing'] = <String, dynamic>{
          'enabled': true,
          'routeOnly': true,
          'destOverride': <String>['http', 'tls', 'quic'],
        };
      }
    }

    _replaceInboundTag(config, from: 'tun-in', to: 'tun');
    _ensureTunUserLevelPolicy(config);
    return jsonEncode(config);
  }

  static Map<String, dynamic> _buildOutbound(ServerConfig server) {
    final protocol = server.protocol.toLowerCase();
    switch (protocol) {
      case 'json':
        throw UnsupportedError('JSON configs are handled at a higher level');
      case 'vless':
        return _buildVless(server);
      default:
        // Servers saved before the app narrowed to VLESS still sit in storage.
        // They reach this point only if the user taps one, and the message is
        // what the UI shows, so name the protocol rather than failing blankly.
        throw UnsupportedError(
          'Протокол ${server.protocol.toUpperCase()} больше не поддерживается',
        );
    }
  }

  static void _replaceInboundTag(
    dynamic value, {
    required String from,
    required String to,
  }) {
    if (value is Map) {
      final inboundTag = value['inboundTag'];
      if (inboundTag == from) {
        value['inboundTag'] = to;
      } else if (inboundTag is List) {
        value['inboundTag'] =
            inboundTag.map((tag) => tag == from ? to : tag).toList();
      }
      for (final child in value.values) {
        _replaceInboundTag(child, from: from, to: to);
      }
    } else if (value is List) {
      for (final child in value) {
        _replaceInboundTag(child, from: from, to: to);
      }
    }
  }

  static void _ensureTunUserLevelPolicy(Map<String, dynamic> config) {
    final policy = _normalizeMap(config['policy']) ?? <String, dynamic>{};
    final levels = _normalizeMap(policy['levels']) ?? <String, dynamic>{};
    levels['8'] = <String, dynamic>{
      'handshake': 4,
      'connIdle': 300,
      'uplinkOnly': 1,
      'downlinkOnly': 1,
    };
    policy['levels'] = levels;
    config['policy'] = policy;
  }

  static Map<String, dynamic> _buildVless(ServerConfig server) {
    final extras = server.extras;
    final flow = extras['flow'] ?? '';
    return <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': <String, dynamic>{
        'vnext': <Map<String, dynamic>>[
          <String, dynamic>{
            'address': server.host,
            'port': server.port,
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': server.uuid,
                'encryption': 'none',
                if (flow.isNotEmpty) 'flow': flow,
              },
            ],
          },
        ],
      },
      'streamSettings': _buildStream(
        network: extras['type'] ?? 'tcp',
        security: extras['security'] ?? 'none',
        sni: extras['sni'] ?? server.host,
        extras: extras,
      ),
    };
  }

  static const int _statsApiPort = 10853;

  static Map<String, dynamic> _statsApiInbound() => <String, dynamic>{
        'tag': 'api-in',
        'listen': '127.0.0.1',
        'port': _statsApiPort,
        'protocol': 'dokodemo-door',
        'settings': <String, dynamic>{'address': '127.0.0.1'},
      };

  static Map<String, dynamic> _statsApiRoutingRule() => <String, dynamic>{
        'type': 'field',
        'inboundTag': <String>['api-in'],
        'outboundTag': 'api',
      };

  static List<Map<String, dynamic>> _buildRuDirectRoutingRules({
    String? inboundTag,
  }) {
    return [
      <String, dynamic>{
        'type': 'field',
        if (inboundTag != null) 'inboundTag': <String>[inboundTag],
        'domain': _ruDirectDomainRules,
        'outboundTag': 'direct',
      },
      <String, dynamic>{
        'type': 'field',
        if (inboundTag != null) 'inboundTag': <String>[inboundTag],
        'ip': _ruDirectIpRules,
        'outboundTag': 'direct',
      },
    ];
  }

  static Map<String, dynamic> _buildStream({
    required String network,
    required String security,
    required String sni,
    required Map<String, String> extras,
  }) {
    final transport = network.toLowerCase();
    final stream = <String, dynamic>{'network': transport};

    switch (security) {
      case 'tls':
        stream['security'] = 'tls';
        stream['tlsSettings'] = <String, dynamic>{
          'serverName': sni,
          'allowInsecure': false,
          if ((extras['fp'] ?? '').isNotEmpty) 'fingerprint': extras['fp'],
          if ((extras['alpn'] ?? '').isNotEmpty)
            'alpn': extras['alpn']!.split(','),
        };
      case 'reality':
        stream['security'] = 'reality';
        stream['realitySettings'] = <String, dynamic>{
          'serverName': sni,
          'fingerprint': extras['fp'] ?? 'chrome',
          'shortId': extras['sid'] ?? '',
          'publicKey': extras['pbk'] ?? '',
        };
      default:
        stream['security'] = 'none';
    }

    switch (transport) {
      case 'ws':
        stream['wsSettings'] = <String, dynamic>{
          'path': extras['path'] ?? '/',
          'headers': <String, dynamic>{'Host': extras['host'] ?? sni},
        };
      case 'grpc':
        stream['grpcSettings'] = <String, dynamic>{
          'serviceName': extras['serviceName'] ?? '',
        };
      case 'h2':
      case 'http':
        stream['httpSettings'] = <String, dynamic>{
          'host': <String>[sni],
          'path': extras['path'] ?? '/',
        };
      case 'xhttp':
        stream['xhttpSettings'] = <String, dynamic>{
          'path': extras['path'] ?? '/',
          if ((extras['host'] ?? '').isNotEmpty) 'host': extras['host'],
          if ((extras['mode'] ?? '').isNotEmpty) 'mode': extras['mode'],
        };
      default:
        break;
    }

    return stream;
  }

  static List<String> _resolveDnsServers(ServerConfig server) {
    final subscriptionId = server.subscriptionId;
    if (subscriptionId == null) {
      return _fallbackDnsServers;
    }

    for (final subscription in StorageService.getSubscriptions()) {
      if (subscription.id == subscriptionId &&
          subscription.dnsServers.isNotEmpty) {
        return subscription.dnsServers;
      }
    }
    return _fallbackDnsServers;
  }

  static bool _isJsonServer(ServerConfig server) =>
      server.protocol.toLowerCase() == 'json' &&
      (server.extras['configJson'] ?? '').isNotEmpty;

  static String _buildImportedJsonConfig(
    ServerConfig server, {
    required bool tunnelMode,
    required bool statsApi,
    required bool enableRuRouting,
  }) {
    final imported = _parseImportedConfig(server);
    final outbounds = _normalizeOutbounds(imported['outbounds']);
    if (outbounds.isEmpty) {
      throw const FormatException('JSON config has no outbounds');
    }

    final importedRouting = _normalizeMap(imported['routing']);
    final importedRules = _normalizeRules(importedRouting?['rules']);
    final dns = _resolveImportedDns(imported, server);

    final config = Map<String, dynamic>.from(imported)
      ..remove('remarks')
      ..remove('meta')
      ..remove('inbounds')
      ..remove('outbounds')
      ..remove('routing')
      ..remove('dns');

    config['log'] = _normalizeMap(imported['log']) ??
        <String, dynamic>{'loglevel': 'warning'};
    config['dns'] = dns;
    config['inbounds'] = tunnelMode
        ? <Map<String, dynamic>>[
            <String, dynamic>{
              'tag': 'tun-in',
              'port': 0,
              'protocol': 'tun',
              'settings': <String, dynamic>{
                'name': 'chrnet0',
                'MTU': 1500,
                'userLevel': 8,
                'address': <String>['10.0.0.1/24'],
                'autoRoute': true,
                'strictRoute': false,
              },
            },
            if (statsApi) _statsApiInbound(),
          ]
        : <Map<String, dynamic>>[
            <String, dynamic>{
              'tag': 'socks',
              'listen': '127.0.0.1',
              'port': 10808,
              'protocol': 'socks',
              'settings': <String, dynamic>{'udp': true},
              'sniffing': <String, dynamic>{
                'enabled': true,
                'destOverride': <String>['http', 'tls'],
              },
            },
            <String, dynamic>{
              'tag': 'http',
              'listen': '127.0.0.1',
              'port': 10809,
              'protocol': 'http',
              'settings': <String, dynamic>{},
            },
            if (statsApi) _statsApiInbound(),
          ];
    config['outbounds'] = _ensureDirectAndBlockOutbounds(outbounds);
    config['routing'] = _buildImportedRouting(
      importedRouting,
      importedRules,
      outbounds,
      tunnelMode: tunnelMode,
      statsApi: statsApi,
      enableRuRouting: enableRuRouting,
    );

    if (statsApi) {
      config['stats'] = <String, dynamic>{};
      config['api'] = <String, dynamic>{
        'tag': 'api',
        'services': <String>['StatsService'],
      };
      config['policy'] = <String, dynamic>{
        'system': <String, dynamic>{
          'statsOutboundDownlink': true,
          'statsOutboundUplink': true,
        },
      };
    }

    return jsonEncode(config);
  }

  static Map<String, dynamic> _parseImportedConfig(ServerConfig server) {
    final raw = server.extras['configJson'];
    if (raw == null || raw.trim().isEmpty) {
      throw const FormatException('Missing configJson');
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON config must be an object');
    }
    return decoded;
  }

  static Map<String, dynamic>? _normalizeMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  static List<Map<String, dynamic>> _normalizeOutbounds(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  static List<Map<String, dynamic>> _normalizeRules(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  /// Geo categories present in the trimmed datasets we ship.
  ///
  /// Keep in sync with the generation commands in tools/geo/README.md. Anything
  /// outside these sets is unresolvable at runtime and must be stripped before
  /// the config reaches the core.
  static const Set<String> shippedGeoIpCategories = {'ru', 'private'};

  static const Set<String> shippedGeoSiteCategories = {
    'category-ru',
    'category-gov-ru',
    'category-media-ru',
    'category-ecommerce-ru',
    'category-entertainment-ru',
    'category-retail-ru',
    'category-ads-all',
    'category-antivirus',
    'private',
    'yandex',
    'vk',
    'mailru',
    'mailru-group',
    'rutracker',
    'rutube',
    'telegram',
  };

  /// Whether the core can resolve `geoip:x` / `geosite:x` as written.
  static bool _isResolvableGeoToken(String token) {
    String bare(String value) =>
        value.startsWith('!') ? value.substring(1) : value;

    // `geosite:x@attr` narrows a category by attribute; the category still has
    // to be present, and the attribute does not change which file is loaded.
    if (token.startsWith('geosite:')) {
      final category = bare(token.substring('geosite:'.length)).split('@').first;
      return shippedGeoSiteCategories.contains(category);
    }
    if (token.startsWith('geoip:')) {
      // `geoip:!ru` negates a category but still needs it loaded.
      return shippedGeoIpCategories.contains(bare(token.substring('geoip:'.length)));
    }
    return true;
  }

  /// Drops geo references the trimmed datasets cannot resolve.
  ///
  /// Only user-imported raw JSON can contain them — everything this class
  /// generates itself stays within [shippedGeoIpCategories]. Xray refuses to
  /// start when a rule names a missing category, so an untouched import would
  /// mean "cannot connect at all". Dropping the reference instead costs the
  /// user that one rule: the affected traffic falls through to the config's
  /// default route, which for a VPN config means through the tunnel rather
  /// than around it.
  static List<Map<String, dynamic>> _stripUnresolvableGeoRules(
    List<Map<String, dynamic>> rules,
  ) {
    const matcherKeys = ['ip', 'domain'];
    final kept = <Map<String, dynamic>>[];

    for (final rule in rules) {
      final next = Map<String, dynamic>.from(rule);
      var hadMatcher = false;
      var lostEveryMatcher = true;

      for (final key in matcherKeys) {
        final values = next[key];
        if (values is! List) continue;
        hadMatcher = true;

        final survivors = values
            .where((value) => _isResolvableGeoToken(
                  value?.toString().trim().toLowerCase() ?? '',
                ))
            .toList();

        if (survivors.isEmpty) {
          next.remove(key);
        } else {
          next[key] = survivors;
          lostEveryMatcher = false;
        }
      }

      // A rule that only ever matched on geo data now matches everything, which
      // would hijack all traffic. Drop it rather than let it widen.
      if (hadMatcher && lostEveryMatcher) continue;
      kept.add(next);
    }

    return kept;
  }

  /// Strips unresolvable geo references from an imported `dns` block.
  ///
  /// This is a separate walk from [_stripUnresolvableGeoRules] because Xray
  /// builds DNS before routing and fails there first: a config carrying
  /// `geosite:category-ru` under `dns.servers[].domains` dies with
  /// "failed to build DNS configuration", never reaching the routing rules.
  static Map<String, dynamic> _stripUnresolvableGeoDns(
    Map<String, dynamic> dns,
  ) {
    final servers = dns['servers'];
    if (servers is! List) return dns;

    final kept = <dynamic>[];
    for (final server in servers) {
      // Plain string entries ("1.1.1.1") carry no geo references.
      if (server is! Map) {
        kept.add(server);
        continue;
      }

      final next = Map<String, dynamic>.from(server);
      var droppedEveryDomain = false;

      for (final key in const ['domains', 'expectIPs', 'expectIps']) {
        final values = next[key];
        if (values is! List) continue;

        final survivors = values
            .where((value) => _isResolvableGeoToken(
                  value?.toString().trim().toLowerCase() ?? '',
                ))
            .toList();

        if (survivors.length == values.length) continue;
        if (survivors.isEmpty) {
          next.remove(key);
          // A server scoped to a domain list becomes a catch-all once that list
          // is gone, which would silently take over all name resolution.
          if (key == 'domains') droppedEveryDomain = true;
        } else {
          next[key] = survivors;
        }
      }

      if (droppedEveryDomain) continue;
      kept.add(next);
    }

    // Never hand the core an empty server list — it would have no resolver.
    if (kept.isEmpty) {
      return <String, dynamic>{
        ...dns,
        'servers': List<String>.from(_fallbackDnsServers),
      };
    }

    return <String, dynamic>{...dns, 'servers': kept};
  }

  static Map<String, dynamic> _resolveImportedDns(
    Map<String, dynamic> imported,
    ServerConfig server,
  ) {
    final importedDns = _normalizeMap(imported['dns']);
    if (importedDns != null) {
      return _stripUnresolvableGeoDns(importedDns);
    }

    return <String, dynamic>{'servers': _resolveDnsServers(server)};
  }

  static List<Map<String, dynamic>> _ensureDirectAndBlockOutbounds(
    List<Map<String, dynamic>> outbounds,
  ) {
    final next = outbounds
        .map((outbound) => Map<String, dynamic>.from(outbound))
        .toList();

    final hasDirect = next.any(
      (outbound) =>
          (outbound['tag']?.toString() ?? '') == 'direct' ||
          (outbound['protocol']?.toString() ?? '') == 'freedom',
    );
    final hasBlock = next.any(
      (outbound) =>
          (outbound['tag']?.toString() ?? '') == 'block' ||
          (outbound['protocol']?.toString() ?? '') == 'blackhole',
    );

    if (!hasDirect) {
      next.add(<String, dynamic>{'tag': 'direct', 'protocol': 'freedom'});
    }
    if (!hasBlock) {
      next.add(<String, dynamic>{'tag': 'block', 'protocol': 'blackhole'});
    }

    return next;
  }

  static Map<String, dynamic> _buildImportedRouting(
    Map<String, dynamic>? importedRouting,
    List<Map<String, dynamic>> importedRules,
    List<Map<String, dynamic>> outbounds, {
    required bool tunnelMode,
    required bool statsApi,
    required bool enableRuRouting,
  }) {
    final rules = <Map<String, dynamic>>[
      if (statsApi) _statsApiRoutingRule(),
      if (tunnelMode) ..._buildJsonTunnelServerDirectRules(outbounds),
      if (tunnelMode)
        <String, dynamic>{
          'type': 'field',
          'inboundTag': <String>['tun-in'],
          'ip': <String>[
            '127.0.0.0/8',
            '10.0.0.0/8',
            '172.16.0.0/12',
            '192.168.0.0/16',
          ],
          'outboundTag': 'direct',
        }
      else
        <String, dynamic>{
          'type': 'field',
          'outboundTag': 'direct',
          'ip': <String>[
            '127.0.0.0/8',
            '10.0.0.0/8',
            '172.16.0.0/12',
            '192.168.0.0/16',
          ],
        },
      if (enableRuRouting)
        ..._buildRuDirectRoutingRules(inboundTag: tunnelMode ? 'tun-in' : null),
      ..._stripUnresolvableGeoRules(importedRules),
    ];

    return <String, dynamic>{
      ...?importedRouting,
      'domainStrategy': importedRouting?['domainStrategy'] ?? 'IPIfNonMatch',
      'rules': rules,
    };
  }

  static List<Map<String, dynamic>> _buildJsonTunnelServerDirectRules(
    List<Map<String, dynamic>> outbounds,
  ) {
    final rules = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final outbound in outbounds) {
      final target = _extractJsonOutboundTarget(outbound);
      if (target == null || !seen.add('${target.type}:${target.value}')) {
        continue;
      }

      rules.add(<String, dynamic>{
        'type': 'field',
        'inboundTag': <String>['tun-in'],
        'outboundTag': 'direct',
        if (target.type == 'ip')
          'ip': <String>[target.value]
        else
          'domain': <String>[target.value],
      });
    }

    return rules;
  }

  static ({String type, String value})? _extractJsonOutboundTarget(
    Map<String, dynamic> outbound,
  ) {
    final settings = _normalizeMap(outbound['settings']);
    if (settings == null) return null;

    final vnext = settings['vnext'];
    if (vnext is List && vnext.isNotEmpty && vnext.first is Map) {
      final address = (vnext.first as Map)['address']?.toString().trim() ?? '';
      if (address.isNotEmpty) {
        return (
          type: _looksLikeIpAddress(address) ? 'ip' : 'domain',
          value: address,
        );
      }
    }

    final servers = settings['servers'];
    if (servers is List && servers.isNotEmpty && servers.first is Map) {
      final address =
          (servers.first as Map)['address']?.toString().trim() ?? '';
      if (address.isNotEmpty) {
        return (
          type: _looksLikeIpAddress(address) ? 'ip' : 'domain',
          value: address,
        );
      }
    }

    final address = settings['address']?.toString().trim() ?? '';
    if (address.isNotEmpty) {
      return (
        type: _looksLikeIpAddress(address) ? 'ip' : 'domain',
        value: address,
      );
    }

    return null;
  }

  static bool _looksLikeIpAddress(String host) {
    return RegExp(r'^[\d.]+$').hasMatch(host) || host.contains(':');
  }

  static bool _isProxyOutbound(Map<String, dynamic> outbound) {
    final protocol = outbound['protocol']?.toString().trim().toLowerCase();
    if (protocol == null || protocol.isEmpty) return false;
    return protocol != 'freedom' &&
        protocol != 'blackhole' &&
        protocol != 'dns' &&
        protocol != 'socks' &&
        protocol != 'http' &&
        protocol != 'loopback';
  }

  static bool _isProxyOutboundWithEndpoint(Map<String, dynamic> outbound) {
    return _isProxyOutbound(outbound) &&
        _extractJsonOutboundTarget(outbound) != null;
  }
}
