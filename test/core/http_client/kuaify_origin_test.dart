import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/kuaify_origin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('initializes Cloudflare Origin CA security context', () {
    expect(() => KuaifyOrigin.securityContext, returnsNormally);
  });

  test('pins the primary panel domain to the production origin', () {
    expect(KuaifyOrigin.addressesForHost('kuaifei.top'), ['34.92.219.162']);
    expect(KuaifyOrigin.connectionAddressesForHost('KUAIFEI.TOP.'), ['34.92.219.162']);
    expect(KuaifyOrigin.addressesForHost('node.kuaifei.top'), isEmpty);
    expect(KuaifyOrigin.addressesForHost('kuaifei.cc.cd'), isEmpty);
    expect(KuaifyOrigin.connectionAddressesForHost('xz.kuaity.top'), KuaifyOrigin.cloudflareEdgeFallbackAddresses);
    expect(KuaifyOrigin.exportCoreRecords()['kuaifei.top'], ['34.92.219.162']);
  });
  test('matches exact records before the longest wildcard and persists the config', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const config = OriginDnsConfig(
      source: 'kuaifei.top',
      revision: 42,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      authEndpoints: [],
      records: {
        '*.kuaifei.top': ['34.92.219.162'],
        '*.edge.kuaifei.top': ['203.0.113.10'],
        'node.kuaifei.top': ['198.51.100.20'],
      },
    );

    expect(await KuaifyOrigin.replace(preferences, config), isTrue);
    expect(KuaifyOrigin.addressesForHost('NODE.KUAIFEI.TOP.'), ['198.51.100.20']);
    expect(KuaifyOrigin.addressesForHost('hk.edge.kuaifei.top'), ['203.0.113.10']);
    expect(KuaifyOrigin.addressesForHost('other.kuaifei.top'), ['34.92.219.162']);
    expect(KuaifyOrigin.addressesForHost('kuaifei.top'), ['34.92.219.162']);
    expect(KuaifyOrigin.addressesForHost('example.com'), isEmpty);

    KuaifyOrigin.restore(preferences);
    expect(KuaifyOrigin.config.revision, 42);
    final exportedRecords = KuaifyOrigin.exportCoreRecords();
    expect(exportedRecords['*.kuaifei.top'], ['34.92.219.162']);
    expect(exportedRecords['*.edge.kuaifei.top'], ['203.0.113.10']);
    expect(exportedRecords['node.kuaifei.top'], ['198.51.100.20']);
    expect(exportedRecords['kuaifei.top'], ['34.92.219.162']);
  });

  test('parses dynamic JSON address lists without runtime casts', () {
    final config = OriginDnsConfig.fromJson({
      'source': 'kuaifei.top',
      'revision': 43,
      'refresh_interval': 900,
      'records': {
        '*.kuaifei.top': ['34.92.219.162', 'invalid'],
        'node.kuaifei.top': ['198.51.100.20'],
      },
    });

    expect(config.records['*.kuaifei.top'], ['34.92.219.162']);
    expect(config.records['node.kuaifei.top'], ['198.51.100.20']);
  });

  test('parses dynamic endpoint capability lists without an unsafe cast', () {
    final config = OriginDnsConfig.fromJson({
      'source': 'kuaifei.top',
      'revision': 45,
      'records': {
        'panel.example.com': ['198.51.100.45'],
      },
      'auth_endpoints': <dynamic>[
        {
          'id': 'primary',
          'url': 'https://kuaifei.top',
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
      'kuaifei.top',
      'wk.kuaifei.top',
      'deep.wk.kuaifei.top',
      'kuaifei.cc.cd',
      'wk.kuaifei.cc.cd',
      'kuaifj.top',
      'wk.kuaifj.top',
      'kuaify.top',
      'wk.kuaify.top',
    ]) {
      expect(KuaifyOrigin.isProtectedPanelHost(host), isFalse, reason: host);
      expect(KuaifyOrigin.prefersRelayForPanelHost(host), isFalse, reason: host);
    }
  });

  test('keeps the last usable origin DNS cache when refresh data is unusable', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const config = OriginDnsConfig(
      source: 'kuaifei.top',
      revision: 44,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      authEndpoints: [],
      records: {
        'node.kuaifei.top': ['198.51.100.44'],
      },
    );

    expect(await KuaifyOrigin.replace(preferences, config), isTrue);
    expect(await KuaifyOrigin.replace(preferences, const OriginDnsConfig.empty()), isFalse);
    expect(KuaifyOrigin.addressesForHost('node.kuaifei.top'), ['198.51.100.44']);

    KuaifyOrigin.restore(preferences);
    expect(KuaifyOrigin.addressesForHost('node.kuaifei.top'), ['198.51.100.44']);
  });
  test('enforces strictly monotonic origin DNS revisions', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const base = OriginDnsConfig(
      source: 'kuaifei.top',
      revision: 100,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.kuaifei.top': ['198.51.100.100'],
      },
      authEndpoints: [],
    );
    const older = OriginDnsConfig(
      source: 'kuaifei.top',
      revision: 99,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.kuaifei.top': ['198.51.100.99'],
      },
      authEndpoints: [],
    );
    const newer = OriginDnsConfig(
      source: 'kuaifei.top',
      revision: 101,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.kuaifei.top': ['198.51.100.101'],
      },
      authEndpoints: [],
    );
    const collision = OriginDnsConfig(
      source: 'kuaifei.top',
      revision: 101,
      refreshInterval: Duration(minutes: 15),
      bootstrapRefreshInterval: Duration(hours: 6),
      records: {
        'node.kuaifei.top': ['203.0.113.101'],
      },
      authEndpoints: [],
    );

    expect(await KuaifyOrigin.replace(preferences, base), isTrue);
    expect(await KuaifyOrigin.replace(preferences, older), isFalse);
    expect(KuaifyOrigin.config.revision, 100);
    expect(await KuaifyOrigin.replace(preferences, base), isFalse);
    expect(await KuaifyOrigin.replace(preferences, newer), isTrue);
    expect(() => KuaifyOrigin.replace(preferences, collision), throwsA(isA<OriginDnsRevisionCollision>()));
    expect(KuaifyOrigin.addressesForHost('node.kuaifei.top'), ['198.51.100.101']);
  });
}
