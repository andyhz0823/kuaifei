import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Cloudflare 边缘 IP 自动优选（移植自 kuaify v5.0.1 的同名实现）。
///
/// 背景：面板域名 `www.tkya.cc.cd` 走 CF 代理，DNS 被污染时客户端只能靠写死的
/// 边缘 IP 兜底。CF 是 anycast + 按 SNI 路由，大部分边缘 IP 都能服务任意 zone，
/// 所以可以探测一批已知边缘 IP，挑当前网络下**真正能用**且最快的几个缓存起来。
///
/// 🔴 必须验证 HTTP 状态码，不能只看 TLS 握手：实测 104.16.132.229 /
/// 104.19.192.29 / 162.159.36.1 / 162.159.46.1 这些边缘能完成握手，但对我们的
/// zone 直接返回 403。只测握手会把它们选进来，导致登录/订阅全部 403。
class EdgeProbe {
  const EdgeProbe._();

  static const preferenceKey = 'origin_edge_ip_cache_v3';
  static const cacheTtl = Duration(hours: 6);
  static const keepCount = 3;

  static const _timeout = Duration(seconds: 3);

  /// 候选边缘 IP：覆盖 104.16~104.22 / 172.66~172.67 / 188.114 / 162.159 网段。
  /// 前 6 个是 tkya 面板当前解析到并实测可用的地址（作为基准）。
  static const candidateAddresses = <String>[
    '104.21.50.151',
    '104.21.34.178',
    '172.67.163.238',
    '172.67.163.144',
    '104.17.0.1',
    '104.18.0.1',
    '104.21.84.66',
    '172.67.187.171',
    '104.21.35.212',
    '172.67.179.226',
    '104.17.26.41',
    '104.18.32.115',
    '104.20.28.5',
    '104.22.4.10',
    '172.66.0.96',
    '188.114.96.1',
    '188.114.97.1',
  ];

  /// 对每个候选 IP 发一次真实 HTTPS 请求（[probeUri]，通常是面板根路径），
  /// 只有返回 200 的才算可用，再按耗时排序取最快的 [keep] 个。
  static Future<List<String>> probe(Uri probeUri, {int keep = keepCount}) async {
    if (probeUri.scheme != 'https' || probeUri.host.isEmpty) return const [];

    final results = await Future.wait(
      candidateAddresses.map((address) async => MapEntry(address, await _probeMs(address, probeUri))),
    );

    final reachable = results.where((entry) => entry.value >= 0).toList()
      ..sort((left, right) => left.value.compareTo(right.value));

    if (reachable.isEmpty) return const [];
    return reachable.take(keep).map((entry) => entry.key).toList(growable: false);
  }

  /// 返回「握手 + 首字节」耗时（毫秒）；非 200 或异常返回 -1。
  static Future<int> _probeMs(String address, Uri probeUri) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = _timeout;
      // 强制连到候选 IP，但 URI 的 host 保持不变 ⇒ TLS SNI 与 Host 头仍是真实域名。
      client.connectionFactory = (requestUri, proxyHost, proxyPort) async {
        final socket = await Socket.connect(address, 443, timeout: _timeout);
        return ConnectionTask.fromSocket(Future<Socket>.value(socket), () {});
      };

      final stopwatch = Stopwatch()..start();
      final request = await client.getUrl(probeUri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      await response.drain<void>().timeout(_timeout);
      stopwatch.stop();

      // 403 / 521 等一律视为不可用。
      if (response.statusCode != HttpStatus.ok) return -1;
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      client?.close(force: true);
    }
  }

  /// 读取缓存：`{"hosts": {"<host>": ["ip", ...]}, "at": <epoch ms>}`，过期返回空。
  static Map<String, List<String>> readCache(SharedPreferences preferences) {
    final raw = preferences.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final hosts = decoded['hosts'];
      final at = decoded['at'];
      if (hosts is! Map || at is! num) return const {};
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      if (DateTime.now().difference(cachedAt) > cacheTtl) return const {};
      final result = <String, List<String>>{};
      for (final entry in hosts.entries) {
        final ips = entry.value;
        if (ips is! List) continue;
        final valid = ips.whereType<String>().where((ip) => InternetAddress.tryParse(ip) != null).toList(growable: false);
        if (valid.isNotEmpty) result[entry.key.toString()] = valid;
      }
      return Map<String, List<String>>.unmodifiable(result);
    } catch (_) {
      return const {};
    }
  }

  static Future<void> writeCache(SharedPreferences preferences, Map<String, List<String>> hosts) async {
    if (hosts.isEmpty) return;
    await preferences.setString(
      preferenceKey,
      jsonEncode({'hosts': hosts, 'at': DateTime.now().millisecondsSinceEpoch}),
    );
  }
}
