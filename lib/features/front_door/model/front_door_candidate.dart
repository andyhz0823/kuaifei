import 'dart:io';

/// 优选候选（一个可拨号的连接地址 + 端口）。
class FrontDoorCandidate {
  const FrontDoorCandidate({required this.host, this.port = 443, this.remark});

  /// IPv4 或域名
  final String host;
  final int port;

  /// 来源标注（仅日志/调试用）
  final String? remark;

  String get key => '$host:$port';

  bool get isIpv4 => InternetAddress.tryParse(host) is InternetAddress;

  String get display => '$host:$port';

  @override
  String toString() => display;
}

/// 单个候选的吞吐测量结果。
class ProbeResult {
  const ProbeResult({
    required this.candidate,
    required this.mbps,
    required this.rttMs,
    required this.bytes,
  });

  final FrontDoorCandidate candidate;

  /// 稳态下行吞吐（Mbps）
  final double mbps;

  /// 首字节耗时（毫秒），流内最小值
  final int rttMs;

  /// 本次实际下载字节数（排查「测了个空响应」用）
  final int bytes;

  /// 排序：Mbps 降序，同值比 RTT。
  static int compare(ProbeResult left, ProbeResult right) {
    final bySpeed = right.mbps.compareTo(left.mbps);
    if (bySpeed != 0) return bySpeed;
    return left.rttMs.compareTo(right.rttMs);
  }

  @override
  String toString() => '${candidate.display} ${mbps.toStringAsFixed(2)}Mbps/${rttMs}ms/${bytes}B';
}

/// 优选任务状态机。
enum FrontDoorStatus { idle, fetching, probing, writing, done, failed, skipped }

/// 一次优选任务的结果摘要。
class FrontDoorOutcome {
  const FrontDoorOutcome({
    required this.status,
    required this.message,
    this.best = const [],
    this.candidates = 0,
    this.bytes = 0,
    this.clonedNodes = 0,
    this.profileChanged = false,
  });

  final FrontDoorStatus status;
  final String message;
  final List<ProbeResult> best;

  /// 参与测速的候选数（降级后）
  final int candidates;

  /// 本次消耗流量（字节）
  final int bytes;

  /// 生成的克隆节点数
  final int clonedNodes;

  /// 是否真的改写了 profile 文件
  final bool profileChanged;

  bool get succeeded => status == FrontDoorStatus.done;

  String get summary {
    if (best.isEmpty) return message;
    final top = best.take(5).map((e) => '${e.candidate.host} ${e.mbps.toStringAsFixed(1)}M').join(' · ');
    return '$message｜$top';
  }
}
