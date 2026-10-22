import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/front_door/data/front_door_source.dart';
import 'package:hiddify/features/front_door/data/node_cloner.dart';
import 'package:hiddify/features/front_door/data/throughput_prober.dart';
import 'package:hiddify/features/front_door/model/front_door_candidate.dart';

void main() {
  const node =
      'vless://e6c7f8a9-bbbb-4ccc-8ddd-1234567890ab@wefdaafafafaf.tkya.us.ci:8443'
      '?type=ws&security=tls&host=wefdaafafafaf.tkya.us.ci'
      '&sni=wefdaafafafaf.tkya.us.ci&path=%2Fws%2Fpath#美国dedi-LA-2-ws';

  const reality =
      'vless://e6c7f8a9-bbbb-4ccc-8ddd-1234567890ab@107.172.186.21:65529'
      '?type=tcp&security=reality&sni=www.apple.com#美国dedi-LA-2';

  group('NodeCloner.parseNode', () {
    test('parses vless+ws+tls node', () {
      final info = NodeCloner.parseNode(node)!;
      expect(info.address, 'wefdaafafafaf.tkya.us.ci');
      expect(info.port, 8443);
      expect(info.sni, 'wefdaafafafaf.tkya.us.ci');
      expect(info.targetHost, 'wefdaafafafaf.tkya.us.ci');
    });

    test('rejects reality / non-ws / non-vless', () {
      expect(NodeCloner.parseNode(reality), isNull);
      expect(NodeCloner.parseNode(node.replaceAll('type=ws', 'type=tcp')), isNull);
      expect(NodeCloner.parseNode('trojan://p@a.com:443?type=ws&security=tls&sni=a.com#a'), isNull);
      expect(NodeCloner.parseNode('ss://YWVz#a'), isNull);
    });

    test('defaults port to 443 and falls back to ws host for sni', () {
      const noPort = 'vless://uuid@a.example.com?type=ws&security=tls&host=cdn.example.com&path=/ws#n';
      final info = NodeCloner.parseNode(noPort)!;
      expect(info.port, 443);
      expect(info.sni, 'cdn.example.com');
    });
  });

  group('NodeCloner.apply（克隆）', () {
    test('copies matched node N times, keeps original, only address changes', () {
      final lines = <String>['# comment', node, '', reality];
      final out = NodeCloner.apply(
        lines,
        addresses: const ['1.1.1.1', '2.2.2.2', '3.3.3.3', '4.4.4.4', '5.5.5.5'],
        keywords: const ['tkya.us.ci'],
        copies: 5,
      );
      // 原 4 行 + 5 个克隆
      expect(out.length, 9);
      // 原节点未被改动
      expect(out[1], node);
      // reality 节点不参与
      expect(out.where((l) => l.contains('security=reality')).length, 1);
      final clones = out.where((l) => NodeCloner.isClone(l)).toList();
      expect(clones.length, 5);
      for (var i = 0; i < 5; i++) {
        final info = NodeCloner.parseNode(clones[i])!;
        expect(info.address, '${i + 1}.${i + 1}.${i + 1}.${i + 1}');
        expect(info.port, 8443);
        expect(info.sni, 'wefdaafafafaf.tkya.us.ci');
        expect(clones[i], contains('host=wefdaafafafaf.tkya.us.ci'));
        expect(clones[i], contains('path=%2Fws%2Fpath'));
        expect(NodeCloner.remarkOf(clones[i]), '美国dedi-LA-2-ws-优选${i + 1}');
      }
    });

    test('idempotent: applying twice does not multiply nodes', () {
      final once = NodeCloner.apply(['#', node], addresses: const ['1.1.1.1', '2.2.2.2'], keywords: const ['tkya'], copies: 5);
      final twice = NodeCloner.apply(once, addresses: const ['9.9.9.9'], keywords: const ['tkya'], copies: 5);
      expect(twice.where((l) => NodeCloner.isClone(l)).length, 1);
      // 只剩新地址那一个克隆
      expect(NodeCloner.parseNode(twice.last)!.address, '9.9.9.9');
    });

    test('copies capped by address count and copies param', () {
      final out = NodeCloner.apply([node], addresses: const ['1.1.1.1', '2.2.2.2'], keywords: const ['tkya'], copies: 5);
      expect(out.where((l) => NodeCloner.isClone(l)).length, 2);
      final out2 = NodeCloner.apply([node], addresses: const ['1.1.1.1', '2.2.2.2'], keywords: const ['tkya'], copies: 1);
      expect(out2.where((l) => NodeCloner.isClone(l)).length, 1);
    });

    test('non-matching keywords produce no clones', () {
      final out = NodeCloner.apply([node], addresses: const ['1.1.1.1'], keywords: const ['other.example'], copies: 5);
      expect(out.length, 1);
    });

    test('empty addresses only strips existing clones', () {
      final withClones = NodeCloner.apply([node], addresses: const ['1.1.1.1'], keywords: const ['tkya'], copies: 5);
      final stripped = NodeCloner.apply(withClones, addresses: const [], keywords: const ['tkya'], copies: 5);
      expect(stripped, [node]);
    });
  });

  group('CfstDdnsSource.parseBody', () {
    test('parses plain IP / ip:port / result.csv and skips headers', () {
      const body = '''
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s)
104.21.84.66,4,4,0.00,38.12,42.50
# comment
172.67.187.171
188.114.96.1:8443
not-a-host
''';
      final list = CfstDdnsSource.parseBody(body, max: 10);
      expect(list.map((e) => e.host).toList(), ['104.21.84.66', '172.67.187.171', '188.114.96.1']);
      expect(list.first.port, 443);
      expect(list.last.port, 8443);
    });

    test('respects max and de-duplicates', () {
      final list = CfstDdnsSource.parseBody('1.1.1.1\n1.1.1.1\n2.2.2.2\n3.3.3.3', max: 2);
      expect(list.length, 2);
      expect(list.map((e) => e.host).toList(), ['1.1.1.1', '2.2.2.2']);
    });
  });

  group('ThroughputProber', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('measures throughput against a local server', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final chunk = List<int>.filled(64 * 1024, 7);
      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.binary;
        // 持续写入直到客户端断开或达到上限
        for (var i = 0; i < 400; i++) {
          try {
            request.response.add(chunk);
            await request.response.flush();
          } catch (_) {
            break;
          }
        }
        try {
          await request.response.close();
        } catch (_) {}
      });

      const prober = ThroughputProber(
        streams: 2,
        window: Duration(milliseconds: 400),
        warmup: Duration(milliseconds: 100),
        connectTimeout: Duration(seconds: 2),
      );
      final candidate = FrontDoorCandidate(host: '127.0.0.1', port: server.port);
      final result = await prober.measure(
        candidate,
        probeUri: Uri.parse('http://127.0.0.1:${server.port}/__down'),
      );

      expect(result, isNotNull);
      expect(result!.mbps, greaterThan(0));
      expect(result.bytes, greaterThan(0));
      expect(result.candidate.host, '127.0.0.1');
    });

    test('non-200 response is rejected', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.close();
      });

      const prober = ThroughputProber(
        streams: 1,
        window: Duration(milliseconds: 300),
        warmup: Duration(milliseconds: 50),
        connectTimeout: Duration(seconds: 2),
      );
      final result = await prober.measure(
        FrontDoorCandidate(host: '127.0.0.1', port: server.port),
        probeUri: Uri.parse('http://127.0.0.1:${server.port}/__down'),
      );
      expect(result, isNull);
    });

    test('unreachable candidate is rejected', () async {
      const prober = ThroughputProber(
        streams: 1,
        window: Duration(milliseconds: 200),
        connectTimeout: Duration(milliseconds: 300),
      );
      final result = await prober.measure(
        const FrontDoorCandidate(host: '127.0.0.1', port: 1),
        probeUri: Uri.parse('http://127.0.0.1:1/__down'),
      );
      expect(result, isNull);
    });
  });

  group('ProbeResult ordering', () {
    test('sorts by Mbps desc then rtt asc', () {
      const a = ProbeResult(candidate: FrontDoorCandidate(host: 'a'), mbps: 10, rttMs: 100, bytes: 1);
      const b = ProbeResult(candidate: FrontDoorCandidate(host: 'b'), mbps: 30, rttMs: 200, bytes: 1);
      const c = ProbeResult(candidate: FrontDoorCandidate(host: 'c'), mbps: 10, rttMs: 50, bytes: 1);
      final list = [a, b, c]..sort(ProbeResult.compare);
      expect(list.map((e) => e.candidate.host).toList(), ['b', 'c', 'a']);
    });
  });
}
