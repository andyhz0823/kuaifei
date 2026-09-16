import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/tkya_origin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('initializes Cloudflare Origin CA security context', () {
    expect(() => TkyaOrigin.securityContext, returnsNormally);
  });

  test('pins the apex, www and every subdomain to the Cloudflare edge', () {
    // Panel hosts are dialled at the Cloudflare edge; the URI host is kept for
    // TLS SNI and the HTTP Host header so Cloudflare routes back to the origin.
    // The apex is pinned explicitly: a wildcard never matches the apex host, and
    // the apex is exactly what a user types into the panel address field.
    expect(TkyaOrigin.addressesForHost('tkya.cc.cd'), TkyaOrigin.cloudflareEdgeFallbackAddresses);
    expect(TkyaOrigin.addressesForHost('www.tkya.cc.cd'), TkyaOrigin.cloudflareEdgeFallbackAddresses);
    expect(TkyaOrigin.addressesForHost('panel.tkya.cc.cd'), TkyaOrigin.cloudflareEdgeFallbackAddresses);
    expect(TkyaOrigin.connectionAddressesForHost('KK44V.TKYA.CC.CD.'), TkyaOrigin.cloudflareEdgeFallbackAddresses);
    expect(TkyaOrigin.connectionAddressesForHost('xz.tkya.cc.cd'), TkyaOrigin.cloudflareEdgeFallbackAddresses);
    expect(TkyaOrigin.addressesForHost('example.com'), isEmpty);
    expect(TkyaOrigin.exportCoreRecords()['tkya.cc.cd'], TkyaOrigin.cloudflareEdgeFallbackAddresses);
    expect(TkyaOrigin.exportCoreRecords()['*.tkya.cc.cd'], TkyaOrigin.cloudflareEdgeFallbackAddresses);
  });

  test('matches exact records before the longest wildcard and persists the config', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const config = OriginDnsConfig(
      source: 'example.com',
      revision: 42,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      authEndpoints: [],
      records: {
        '*.example.com': ['198.51.100.10'],
        '*.edge.example.com': ['203.0.113.10'],
        'node.example.com': ['198.51.100.20'],
      },
    );

    expect(await TkyaOrigin.replace(preferences, config), isTrue);
    expect(TkyaOrigin.addressesForHost('NODE.EXAMPLE.COM.'), ['198.51.100.20']);
    expect(TkyaOrigin.addressesForHost('hk.edge.example.com'), ['203.0.113.10']);
    expect(TkyaOrigin.addressesForHost('other.example.com'), ['198.51.100.10']);
    expect(TkyaOrigin.addressesForHost('example.com'), ['198.51.100.10']);
    expect(TkyaOrigin.addressesForHost('example.org'), isEmpty);

    TkyaOrigin.restore(preferences);
    expect(TkyaOrigin.config.revision, 42);
    final exportedRecords = TkyaOrigin.exportCoreRecords();
    expect(exportedRecords['*.example.com'], ['198.51.100.10']);
    expect(exportedRecords['*.edge.example.com'], ['203.0.113.10']);
    expect(exportedRecords['node.example.com'], ['198.51.100.20']);
    expect(exportedRecords['example.com'], ['198.51.100.10']);
  });

  test('parses dynamic JSON address lists without runtime casts', () {
    final config = OriginDnsConfig.fromJson({
      'source': 'example.com',
      'revision': 43,
      'refresh_interval': 900,
      'records': {
        '*.example.com': ['198.51.100.10', 'invalid'],
        'node.example.com': ['198.51.100.20'],
      },
    });

    expect(config.records['*.example.com'], ['198.51.100.10']);
    expect(config.records['node.example.com'], ['198.51.100.20']);
  });

  test('parses dynamic endpoint capability lists without an unsafe cast', () {
    final config = OriginDnsConfig.fromJson({
      'source': 'example.com',
      'revision': 45,
      'records': {
        'panel.example.com': ['198.51.100.45'],
      },
      'auth_endpoints': <dynamic>[
        {
          'id': 'primary',
          'url': 'https://example.com',
          'capabilities': <dynamic>['api', 'API', 'subscription', 7, null, ''],
        },
      ],
    });

    expect(config.authEndpoints, hasLength(1));
    expect(config.authEndpoints.single.capabilities, ['api', 'subscription']);
    expect(config.authEndpoints.single.supportsSubscription, isTrue);
  });

  test('does not mark business panel domains as built-in relay-first targets', () {
    for (final host in [
      'tkya.cc.cd',
      'wk.tkya.cc.cd',
      'deep.wk.tkya.cc.cd',
      'example.net',
      'wk.example.net',
      'alpha.example',
      'wk.alpha.example',
      'beta.example',
      'wk.beta.example',
    ]) {
      expect(TkyaOrigin.isProtectedPanelHost(host), isFalse, reason: host);
      expect(TkyaOrigin.prefersRelayForPanelHost(host), isFalse, reason: host);
    }
  });

  test('keeps the last usable origin DNS cache when refresh data is unusable', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const config = OriginDnsConfig(
      source: 'example.com',
      revision: 44,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      authEndpoints: [],
      records: {
        'node.example.com': ['198.51.100.44'],
      },
    );

    expect(await TkyaOrigin.replace(preferences, config), isTrue);
    expect(await TkyaOrigin.replace(preferences, const OriginDnsConfig.empty()), isFalse);
    expect(TkyaOrigin.addressesForHost('node.example.com'), ['198.51.100.44']);

    TkyaOrigin.restore(preferences);
    expect(TkyaOrigin.addressesForHost('node.example.com'), ['198.51.100.44']);
  });

  test('enforces strictly monotonic origin DNS revisions', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const base = OriginDnsConfig(
      source: 'example.com',
      revision: 100,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.example.com': ['198.51.100.100'],
      },
      authEndpoints: [],
    );
    const older = OriginDnsConfig(
      source: 'example.com',
      revision: 99,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.example.com': ['198.51.100.99'],
      },
      authEndpoints: [],
    );
    const newer = OriginDnsConfig(
      source: 'example.com',
      revision: 101,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.example.com': ['198.51.100.101'],
      },
      authEndpoints: [],
    );
    const collision = OriginDnsConfig(
      source: 'example.com',
      revision: 101,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.example.com': ['203.0.113.101'],
      },
      authEndpoints: [],
    );

    expect(await TkyaOrigin.replace(preferences, base), isTrue);
    expect(await TkyaOrigin.replace(preferences, older), isFalse);
    expect(TkyaOrigin.config.revision, 100);
    expect(await TkyaOrigin.replace(preferences, base), isFalse);
    expect(await TkyaOrigin.replace(preferences, newer), isTrue);
    expect(() => TkyaOrigin.replace(preferences, collision), throwsA(isA<OriginDnsRevisionCollision>()));
    expect(TkyaOrigin.addressesForHost('node.example.com'), ['198.51.100.101']);
  });
}
