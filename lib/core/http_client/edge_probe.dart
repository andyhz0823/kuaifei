import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Cloudflare 边缘 IP 自动优选。
///
/// 背景：面板域名（`www.kuaify.cc.cd`）与订阅域名（`*.tkyayun.cc.cd`）都走 CF 代理，
/// DNS 被污染时客户端只能靠写死的边缘 IP 兜底。CF 是 anycast + 按 SNI 路由，
/// 大部分边缘 IP 都能服务任意 zone，所以可以探测一批已知边缘 IP，
/// 挑当前网络下**真正能用**且最快的几个缓存起来。
///
/// 🔴 必须验证 HTTP 状态码，不能只看 TLS 握手：
/// 实测 `104.16.132.229` / `104.19.192.29` / `162.159.36.1` / `162.159.46.1`
/// 这些边缘能完成握手，但对我们的 zone 直接返回 **403**。
/// 只测握手会把它们选进来，导致登录/订阅全部 403（5.0.4 就是这样翻车的）。
class EdgeProbe {
  const EdgeProbe._();

  /// v2：v1 是「只测握手」的版本，缓存里可能混入了返 403 的边缘，直接弃用。
  static const preferenceKey = 'origin_edge_ip_cache_v2';
  static const cacheTtl = Duration(hours: 6);
  static const keepCount = 3;

  static const _timeout = Duration(seconds: 3);

  /// 候选边缘 IP：覆盖 104.16~104.22 / 172.66~172.67 / 188.114 / 162.159 网段，
  /// 前四个是我们两个 zone 当前解析到的地址（作为基准）。
  static const candidateAddresses = <String>[
    '104.21.84.66',
    '172.67.187.171',
    '104.21.35.212',
    '172.67.179.226',
    '104.16.132.229',
    '104.17.26.41',
    '104.18.32.115',
    '104.19.192.29',
    '104.20.28.5',
    '104.22.4.10',
    '172.66.0.96',
    '188.114.96.1',
    '188.114.97.1',
    '162.159.36.1',
    '162.159.46.1',
  ];

  /// 对每个候选 IP 发一次真实 HTTPS 请求（[probeUri]，通常是 bootstrap 接口），
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

  /// 读取缓存：`{"ips": [...], "at": <epoch ms>}`，过期返回空。
  static List<String> readCache(SharedPreferences preferences) {
    final raw = preferences.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final ips = decoded['ips'];
      final at = decoded['at'];
      if (ips is! List || at is! num) return const [];
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      if (DateTime.now().difference(cachedAt) > cacheTtl) return const [];
      return ips.whereType<String>().where((ip) => InternetAddress.tryParse(ip) != null).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> writeCache(SharedPreferences preferences, List<String> ips) async {
    if (ips.isEmpty) return;
    await preferences.setString(preferenceKey, jsonEncode({'ips': ips, 'at': DateTime.now().millisecondsSinceEpoch}));
  }
}
