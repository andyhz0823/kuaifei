import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/kuaifei_origin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('matches exact records before the longest wildcard and persists the config', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const config = OriginDnsConfig(
      source: 'kuaifei.top',
      revision: 42,
      refreshInterval: Duration(minutes: 15),
      records: {
        '*.kuaifei.top': ['34.92.219.162'],
        '*.edge.kuaifei.top': ['203.0.113.10'],
        'node.kuaifei.top': ['198.51.100.20'],
      },
    );

    expect(await KuaifeiOrigin.replace(preferences, config), isTrue);
    expect(KuaifeiOrigin.addressesForHost('NODE.KUAIFEI.TOP.'), ['198.51.100.20']);
    expect(KuaifeiOrigin.addressesForHost('hk.edge.kuaifei.top'), ['203.0.113.10']);
    expect(KuaifeiOrigin.addressesForHost('other.kuaifei.top'), ['34.92.219.162']);
    expect(KuaifeiOrigin.addressesForHost('kuaifei.top'), isEmpty);
    expect(KuaifeiOrigin.addressesForHost('example.com'), isEmpty);

    KuaifeiOrigin.restore(preferences);
    expect(KuaifeiOrigin.config.revision, 42);
    expect(KuaifeiOrigin.exportCoreRecords(), config.records);
  });
}
