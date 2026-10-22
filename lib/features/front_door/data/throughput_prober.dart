import 'dart:async';
import 'dart:io';

import 'package:hiddify/features/front_door/model/front_door_candidate.dart';

/// 吞吐测速器（决策 D1=A：默认目标为 CF 官方 speed 端点，零服务端改动）
///
/// 与「TLS 握手 RTT」的本质区别：RTT 只能反映建连快慢，选不出**带宽**。
/// 实测 107 对华丢包 30%，单流跑不出真实带宽，所以这里用多流并发。
///
/// 手法（与 `EdgeProbe` 一致，已在本项目验证过）：
/// - `HttpClient.connectionFactory` 强制连到候选 IP，
/// - 但 URI 的 host 保持不变 ⇒ TLS SNI 与 HTTP Host 头仍是 `speed.cloudflare.com`；
/// - CF 边缘按 **IP** 分片（anycast），同一边缘 IP 对不同 zone 的接入质量一致，
///   因此用官方 speed 端点排出来的名次对节点链路有效。
///
/// 必须校验 HTTP 200：`EdgeProbe` 的注释记录过 5.0.4 事故 ——
/// `104.16.132.229` 等边缘能握手但对本 zone 返 403，只测握手会把废 IP 选进来。
///
/// 流量护栏：每个候选最多 [maxBytesPerCandidate]，整轮由调用方给总预算；
/// 单流、单候选都按自己的**计时窗口**计算速率，提前触顶不会把数值算低。
class ThroughputProber {
  const ThroughputProber({
    this.streams = 4,
    this.window = const Duration(milliseconds: 1200),
    this.warmup = const Duration(milliseconds: 250),
    this.connectTimeout = const Duration(seconds: 3),
    this.maxBytesPerCandidate = 8 * 1024 * 1024,
  });

  /// 官方吞吐测速端点（32MB 上限，靠窗口提前停止，不会真下完）。
  static final Uri defaultProbeUri = Uri.parse('https://speed.cloudflare.com/__down?bytes=33554432');

  final int streams;
  final Duration window;
  final Duration warmup;
  final Duration connectTimeout;
  final int maxBytesPerCandidate;

  /// 测量单个候选；完全不可用返回 null。
  ///
  /// [consumedBytes] 回传本次实际消耗的流量，供调用方做总预算控制。
  Future<ProbeResult?> measure(
    FrontDoorCandidate candidate, {
    Uri? probeUri,
    void Function(int bytes)? onBytes,
  }) async {
    final uri = probeUri ?? defaultProbeUri;
    final budget = _Budget(maxBytesPerCandidate);

    final results = await Future.wait(
      List.generate(streams, (_) => _stream(candidate.host, uri, budget, onBytes)),
    );

    var mbps = 0.0;
    var bytes = 0;
    var rtt = -1;
    for (final r in results) {
      mbps += r.mbps;
      bytes += r.bytes;
      if (r.firstByteMs >= 0 && (rtt < 0 || r.firstByteMs < rtt)) rtt = r.firstByteMs;
    }
    if (bytes <= 0 || mbps <= 0) return null;
    return ProbeResult(candidate: candidate, mbps: mbps, rttMs: rtt < 0 ? 0 : rtt, bytes: bytes);
  }

  Future<_StreamResult> _stream(String ip, Uri uri, _Budget budget, void Function(int)? onBytes) async {
    HttpClient? client;
    StreamSubscription<List<int>>? subscription;
    try {
      client = HttpClient()..connectionTimeout = connectTimeout;
      client.connectionFactory = (requestUri, proxyHost, proxyPort) async {
        final socket = await Socket.connect(ip, uri.port, timeout: connectTimeout);
        try {
          socket.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        return ConnectionTask.fromSocket(Future<Socket>.value(socket), () {});
      };

      final request = await client.getUrl(uri).timeout(connectTimeout);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final response = await request.close().timeout(connectTimeout);
      if (response.statusCode != HttpStatus.ok) return const _StreamResult.failed();

      final stopwatch = Stopwatch()..start();
      final done = Completer<void>();
      var bytes = 0;
      var countedStartMs = -1;
      var countedMs = 0;
      var firstByteMs = -1;

      void finish() {
        if (countedStartMs >= 0) countedMs = stopwatch.elapsedMilliseconds - countedStartMs;
        if (!done.isCompleted) done.complete();
      }

      subscription = response.listen(
        (chunk) {
          if (firstByteMs < 0) firstByteMs = stopwatch.elapsedMilliseconds;
          final elapsed = stopwatch.elapsedMilliseconds;
          if (elapsed >= warmup.inMilliseconds) {
            if (countedStartMs < 0) countedStartMs = elapsed;
            bytes += chunk.length;
            budget.take(chunk.length, onBytes);
          }
          if (elapsed >= window.inMilliseconds || budget.exhausted) finish();
        },
        onDone: finish,
        onError: (_) => finish(),
        cancelOnError: true,
      );

      await done.future.timeout(window + const Duration(seconds: 2), onTimeout: finish);
      await subscription.cancel();

      if (bytes <= 0 || countedMs <= 0) return const _StreamResult.failed();
      return _StreamResult(
        bytes: bytes,
        mbps: bytes * 8 / 1e6 / (countedMs / 1000),
        firstByteMs: firstByteMs,
      );
    } catch (_) {
      return const _StreamResult.failed();
    } finally {
      try {
        await subscription?.cancel();
      } catch (_) {}
      client?.close(force: true);
    }
  }
}

class _StreamResult {
  const _StreamResult({required this.bytes, required this.mbps, required this.firstByteMs});
  const _StreamResult.failed() : bytes = 0, mbps = 0, firstByteMs = -1;

  final int bytes;
  final double mbps;
  final int firstByteMs;
}

/// 单候选的字节预算（单 isolate 内同步扣减，无需加锁）。
class _Budget {
  _Budget(this.limit);

  final int limit;
  int used = 0;

  bool get exhausted => used >= limit;

  void take(int bytes, void Function(int)? onBytes) {
    used += bytes;
    onBytes?.call(bytes);
  }
}
