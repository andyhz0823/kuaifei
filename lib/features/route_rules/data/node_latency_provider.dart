import 'dart:async';
import 'dart:io';

import 'package:hiddify/features/route_rules/data/available_outbounds_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 节点延迟（TCP 握手 RTT）缓存。
///
/// 为什么自己做而不是用 core 的 URLTest：
/// 路由规则页通常在**未连接**状态下打开，core 没有启动路由，`urlTest`
/// 拿不到任何结果；这里直接对 `server:port` 做一次 TCP connect 计时，
/// 不依赖 core、也不需要先连上。
///
/// 局限：QUIC 系协议（hysteria/hysteria2/tuic）是 UDP，TCP 探测会超时，
/// 这类节点显示「—」，不参与测速。
class NodeLatencyState {
  const NodeLatencyState({this.results = const {}, this.pending = 0, this.testing = false});

  /// tag -> 毫秒；-1 表示探测失败（超时/不可达），键不存在表示尚未测过。
  final Map<String, int> results;

  /// 本轮还剩多少个待测。
  final int pending;

  final bool testing;

  NodeLatencyState copyWith({Map<String, int>? results, int? pending, bool? testing}) {
    return NodeLatencyState(
      results: results ?? this.results,
      pending: pending ?? this.pending,
      testing: testing ?? this.testing,
    );
  }
}

/// UDP 协议，TCP 探测无意义。
const _udpOnlyTypes = {'hysteria', 'hysteria2', 'tuic', 'wireguard', 'quic'};

bool supportsLatencyProbe(OutboundOption option) {
  if (!option.canMeasure) return false;
  return !_udpOnlyTypes.contains(option.type);
}

final nodeLatencyProvider = NotifierProvider<NodeLatencyNotifier, NodeLatencyState>(NodeLatencyNotifier.new);

class NodeLatencyNotifier extends Notifier<NodeLatencyState> {
  static const _concurrency = 8;
  static const _timeout = Duration(seconds: 3);

  @override
  NodeLatencyState build() => const NodeLatencyState();

  /// 批量测速。[force] 为 false 时跳过已有结果的节点。
  Future<void> measure(List<OutboundOption> options, {bool force = false}) async {
    if (state.testing) return;

    final targets = options.where(supportsLatencyProbe).toList(growable: false);
    if (targets.isEmpty) return;

    final todo = force ? targets : targets.where((option) => !state.results.containsKey(option.tag)).toList();
    if (todo.isEmpty) return;

    state = state.copyWith(testing: true, pending: todo.length);
    final results = Map<String, int>.from(state.results);

    for (var index = 0; index < todo.length; index += _concurrency) {
      final batch = todo.skip(index).take(_concurrency).toList(growable: false);
      final measured = await Future.wait(batch.map((option) async => MapEntry(option.tag, await _probe(option))));
      for (final entry in measured) {
        results[entry.key] = entry.value;
      }
      state = state.copyWith(
        results: Map<String, int>.unmodifiable(results),
        pending: todo.length - index - batch.length,
      );
    }

    state = NodeLatencyState(results: Map<String, int>.unmodifiable(results), pending: 0, testing: false);
  }

  Future<int> _probe(OutboundOption option) async {
    Socket? socket;
    try {
      final literal = InternetAddress.tryParse(option.host);
      final addresses = literal != null
          ? <InternetAddress>[literal]
          : await InternetAddress.lookup(option.host).timeout(_timeout);
      if (addresses.isEmpty) return -1;

      final stopwatch = Stopwatch()..start();
      socket = await Socket.connect(addresses.first, option.port, timeout: _timeout);
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      socket?.destroy();
    }
  }
}
