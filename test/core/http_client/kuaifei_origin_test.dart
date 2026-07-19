import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/kuaifei_origin.dart';

void main() {
  group('KuaifeiOrigin', () {
    test('maps production panel hosts to the production origin IP', () {
      expect(KuaifeiOrigin.ipForHost('kuaifei.top'), KuaifeiOrigin.productionIp);
      expect(KuaifeiOrigin.ipForHost('chc.kuaifei.top'), KuaifeiOrigin.productionIp);
      expect(KuaifeiOrigin.ipForHost('random-login-123.kuaifei.top'), KuaifeiOrigin.productionIp);
    });

    test('maps test panel host to the test origin IP', () {
      expect(KuaifeiOrigin.ipForHost('test.kuaifei.top'), KuaifeiOrigin.testIp);
    });

    test('does not rewrite unrelated hosts', () {
      expect(KuaifeiOrigin.ipForHost('example.com'), isNull);
      expect(KuaifeiOrigin.ipForHost('kuaifei.top.example.com'), isNull);
    });
  });
}
