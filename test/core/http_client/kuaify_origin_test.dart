import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/kuaify_origin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('initializes Cloudflare Origin CA security context', () {
    expect(() => KuaifyOrigin.securityContext, returnsNormally);
  });

  test('pins the primary panel domain to the production origin', () {
    expect(KuaifyOrigin.addressesForHost('www.kuaify.cc.cd'), ['104.21.84.66', '172.67.187.171']);
    expect(KuaifyOrigin.connectionAddressesForHost('KUAIFY.CC.CD.'), ['104.21.84.66', '172.67.187.171']);
    expect(KuaifyOrigin.addressesForHost('node.unknown-external.com'), isEmpty);
    expect(KuaifyOrigin.connectionAddressesForHost('xz.kuaify.cc.cd'), KuaifyOrigin.cloudflareEdgeFallbackAddresses);
    expect(KuaifyOrigin.exportCoreRecords()['www.kuaify.cc.cd'], ['104.21.84.66', '172.67.187.171']);
  });

  test('matches exact records before the longest wildcard and persists the config', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const config = OriginDnsConfig(
      source: 'www.kuaify.cc.cd',
      revision: 42,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      authEndpoints: [],
      records: {
        '*.test-brand.cc.cd': ['172.67.179.226'],
        '*.edge.test-brand.cc.cd': ['203.0.113.10'],
        'node.test-brand.cc.cd': ['198.51.100.20'],
      },
    );

    expect(await KuaifyOrigin.replace(preferences, config), isTrue);
    expect(KuaifyOrigin.addressesForHost('NODE.TEST-BRAND.CC.CD.'), ['198.51.100.20']);
    expect(KuaifyOrigin.addressesForHost('hk.edge.test-brand.cc.cd'), ['203.0.113.10']);
    expect(KuaifyOrigin.addressesForHost('other.test-brand.cc.cd'), ['172.67.179.226']);
    expect(KuaifyOrigin.addressesForHost('example.com'), isEmpty);

    KuaifyOrigin.restore(preferences);
    expect(KuaifyOrigin.config.revision, 42);
    final exportedRecords = KuaifyOrigin.exportCoreRecords();
    expect(exportedRecords['*.test-brand.cc.cd'], ['172.67.179.226']);
    expect(exportedRecords['*.edge.test-brand.cc.cd'], ['203.0.113.10']);
    expect(exportedRecords['node.test-brand.cc.cd'], ['198.51.100.20']);
  });

  test('parses dynamic JSON address lists without runtime casts', () {
    final config = OriginDnsConfig.fromJson({
      'source': 'www.kuaify.cc.cd',
      'revision': 43,
      'refresh_interval': 900,
      'records': {
        '*.test-brand.cc.cd': ['172.67.179.226', 'invalid'],
        'node.test-brand.cc.cd': ['198.51.100.20'],
      },
    });

    expect(config.records['*.test-brand.cc.cd'], ['172.67.179.226']);
    expect(config.records['node.test-brand.cc.cd'], ['198.51.100.20']);
  });

  test('parses dynamic endpoint capability lists without an unsafe cast', () {
    final config = OriginDnsConfig.fromJson({
      'source': 'www.kuaify.cc.cd',
      'revision': 45,
      'records': {
        'panel.example.com': ['198.51.100.45'],
      },
      'auth_endpoints': <dynamic>[
        {
          'id': 'primary',
          'url': 'https://www.kuaify.cc.cd',
          'capabilities': <dynamic>['api', 'API', 'subscription', 7, null, ''],
        },
      ],
    });

    expect(config.authEndpoints, hasLength(1));
    expect(config.authEndpoints.single.capabilities, ['api', 'subscription']);
    expect(config.authEndpoints.single.supportsSubscription, isTrue);
  });

  test('expands [randN] subdomain templates in auth endpoint URLs', () {
    final config = OriginDnsConfig.fromJson({
      'source': 'www.kuaify.cc.cd',
      'revision': 46,
      'records': {},
      'auth_endpoints': <dynamic>[
        {
          'id': 'rand-sub',
          'url': 'https://[rand9].kuaify.cc.cd',
          'capabilities': <dynamic>['api'],
        },
      ],
    });

    expect(config.authEndpoints, hasLength(1));
    final endpoint = config.authEndpoints.single;
    expect(endpoint.url, matches(RegExp(r'^https://[a-z0-9]{9}\.kuaify\.cc\.cd$')));
    expect(endpoint.url, isNot(contains('[rand')));
    expect(endpoint.isUsable, isTrue);
  });

  test('does not mark business panel domains as built-in relay-first targets', () {
    for (final host in [
      'www.kuaify.cc.cd',
      'wk.kuaify.cc.cd',
      'deep.wk.kuaify.cc.cd',
      'kuaify.cc.cd',
      'by.tkya.us.ci',
      'node.test-brand.cc.cd',
    ]) {
      expect(KuaifyOrigin.isProtectedPanelHost(host), isFalse, reason: host);
      expect(KuaifyOrigin.prefersRelayForPanelHost(host), isFalse, reason: host);
    }
  });

  test('keeps the last usable origin DNS cache when refresh data is unusable', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const config = OriginDnsConfig(
      source: 'www.kuaify.cc.cd',
      revision: 44,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      authEndpoints: [],
      records: {
        'node.test-brand.cc.cd': ['198.51.100.44'],
      },
    );

    expect(await KuaifyOrigin.replace(preferences, config), isTrue);
    expect(await KuaifyOrigin.replace(preferences, const OriginDnsConfig.empty()), isFalse);
    expect(KuaifyOrigin.addressesForHost('node.test-brand.cc.cd'), ['198.51.100.44']);

    KuaifyOrigin.restore(preferences);
    expect(KuaifyOrigin.addressesForHost('node.test-brand.cc.cd'), ['198.51.100.44']);
  });

  test('enforces strictly monotonic origin DNS revisions', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const base = OriginDnsConfig(
      source: 'www.kuaify.cc.cd',
      revision: 100,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.test-brand.cc.cd': ['198.51.100.100'],
      },
      authEndpoints: [],
    );
    const older = OriginDnsConfig(
      source: 'www.kuaify.cc.cd',
      revision: 99,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.test-brand.cc.cd': ['198.51.100.99'],
      },
      authEndpoints: [],
    );
    const newer = OriginDnsConfig(
      source: 'www.kuaify.cc.cd',
      revision: 101,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.test-brand.cc.cd': ['198.51.100.101'],
      },
      authEndpoints: [],
    );
    const collision = OriginDnsConfig(
      source: 'www.kuaify.cc.cd',
      revision: 101,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.test-brand.cc.cd': ['203.0.113.101'],
      },
      authEndpoints: [],
    );

    expect(await KuaifyOrigin.replace(preferences, base), isTrue);
    expect(await KuaifyOrigin.replace(preferences, older), isFalse);
    expect(KuaifyOrigin.config.revision, 100);
    expect(await KuaifyOrigin.replace(preferences, base), isFalse);
    expect(await KuaifyOrigin.replace(preferences, newer), isTrue);
    expect(() => KuaifyOrigin.replace(preferences, collision), throwsA(isA<OriginDnsRevisionCollision>()));
    expect(KuaifyOrigin.addressesForHost('node.test-brand.cc.cd'), ['198.51.100.101']);
  });
}
