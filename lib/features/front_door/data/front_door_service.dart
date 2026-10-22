import 'dart:io';

import 'package:hiddify/features/front_door/data/front_door_cache.dart';
import 'package:hiddify/features/front_door/data/front_door_source.dart';
import 'package:hiddify/features/front_door/data/node_cloner.dart';
import 'package:hiddify/features/front_door/data/throughput_prober.dart';
import 'package:hiddify/features/front_door/model/front_door_candidate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 优选编排器：候选池 → 吞吐测速 → Top N → 缓存 → 克隆节点 → 写盘。
///
/// 三条硬约束（对应需求 R1/R2/R3）：
/// 1. **只处理 vless+ws+tls**：reality / tcp / grpc 节点一律跳过（`NodeCloner.parseNode`）；
/// 2. **原节点不删**：只追加「-优选N」克隆，幂等（每次先清旧克隆）；
/// 3. **写完不重启**：本项目无热重载，写盘即「下次连接生效」，
///    当前连接零中断 —— 需要立即生效由 UI 的「立即应用」按钮显式触发重连。
class FrontDoorService {
  const FrontDoorService({
    this.prober = const ThroughputProber(),
    this.maxCandidates = 10,
    this.topCount = 5,
    this.totalByteBudget = 60 * 1024 * 1024,
  });

  final ThroughputProber prober;

  /// 参与测速的候选上限（控制时长与流量）
  final int maxCandidates;

  /// 取前 N 名用于克隆
  final int topCount;

  /// 整轮流量预算上限（字节）
  final int totalByteBudget;

  Future<FrontDoorOutcome> run({
    required String profilePath,
    required SharedPreferences preferences,
    required List<String> keywords,
    required List<String> sourceUrls,
    int copies = 5,
    bool forceRefresh = false,
    void Function(String phase, int done, int total)? onProgress,
    bool Function()? isCanceled,
  }) async {
    final file = File(profilePath);
    if (!file.existsSync()) {
      return const FrontDoorOutcome(status: FrontDoorStatus.skipped, message: '配置文件不存在');
    }

    final original = file.readAsStringSync();
    final lines = original.split('\n');

    // 1. 找出参与优选的节点（原节点，非历史克隆）
    final targets = <FrontDoorNodeInfo>[];
    for (final line in lines) {
      if (NodeCloner.isClone(line)) continue;
      final info = NodeCloner.parseNode(line);
      if (info == null) continue;
      if (!NodeCloner.matchesKeywords(line, keywords)) continue;
      if (!targets.any((e) => e.targetHost == info.targetHost && e.port == info.port)) {
        targets.add(info);
      }
    }

    if (targets.isEmpty) {
      // 没有命中节点时，顺手清掉历史克隆（例如关键词改了）
      final cleaned = NodeCloner.stripClones(lines);
      if (cleaned.length != lines.length) {
        file.writeAsStringSync(cleaned.join('\n'));
        return FrontDoorOutcome(
          status: FrontDoorStatus.skipped,
          message: '没有命中 vless+ws+tls 节点，已清理历史优选节点',
          profileChanged: true,
        );
      }
      return const FrontDoorOutcome(
        status: FrontDoorStatus.skipped,
        message: '没有命中的 vless+ws+tls 节点（检查关键词）',
      );
    }

    final target = targets.first;
    final cacheKey = '${target.targetHost}|${target.port}';
    final fingerprint = await FrontDoorCache.networkFingerprint();

    // 2. 缓存命中则跳过测速（0 秒建节点，再靠下一次后台刷新）
    List<ProbeResult> best = const [];
    var bytesUsed = 0;
    if (!forceRefresh) {
      final cached = FrontDoorCache.read(preferences, cacheKey, fingerprint: fingerprint);
      if (cached.isNotEmpty) {
        best = cached
            .map((c) => ProbeResult(candidate: c, mbps: 0, rttMs: 0, bytes: 0))
            .toList(growable: false);
        onProgress?.call('cache', 1, 1);
      }
    }

    // 3. 测速
    if (best.isEmpty) {
      onProgress?.call('fetching', 0, 1);
      final candidates = await resolveCandidates(
        sourceUrls: sourceUrls,
        targetHost: target.targetHost,
        maxCandidates: maxCandidates,
      );
      if (candidates.isEmpty) {
        return const FrontDoorOutcome(status: FrontDoorStatus.failed, message: '候选池为空（优选源与内置列表都不可用）');
      }

      final measured = <ProbeResult>[];
      var done = 0;
      onProgress?.call('probing', 0, candidates.length);
      for (final candidate in candidates) {
        if (isCanceled?.call() ?? false) {
          return FrontDoorOutcome(
            status: FrontDoorStatus.failed,
            message: '已取消',
            best: measured,
            candidates: candidates.length,
            bytes: bytesUsed,
          );
        }
        if (bytesUsed >= totalByteBudget) break;
        final result = await prober.measure(candidate, onBytes: (n) => bytesUsed += n);
        done++;
        onProgress?.call('probing', done, candidates.length);
        if (result != null) measured.add(result);
      }

      if (measured.isEmpty) {
        return FrontDoorOutcome(
          status: FrontDoorStatus.failed,
          message: '全部候选测速失败（尝试 ${candidates.length} 个，消耗 ${(bytesUsed / 1024 / 1024).toStringAsFixed(1)}MB）',
          candidates: candidates.length,
          bytes: bytesUsed,
        );
      }

      measured.sort(ProbeResult.compare);
      best = measured;
      await FrontDoorCache.write(preferences, cacheKey, best, fingerprint: fingerprint);
    }

    // 4. 克隆节点并写盘
    onProgress?.call('writing', 0, 1);
    final addresses = best.take(topCount).map((r) => r.candidate.host).toList(growable: false);
    final nextLines = NodeCloner.apply(lines, addresses: addresses, keywords: keywords, copies: copies);
    final changed = nextLines.join('\n') != original;
    if (changed) file.writeAsStringSync(nextLines.join('\n'));
    onProgress?.call('writing', 1, 1);

    final cloned = nextLines.length - NodeCloner.stripClones(nextLines).length;
    return FrontDoorOutcome(
      status: FrontDoorStatus.done,
      message: changed
          ? '已生成 $cloned 个优选节点（下次连接生效）'
          : '优选节点已是最新，无需改动',
      best: best,
      candidates: best.length,
      bytes: bytesUsed,
      clonedNodes: cloned,
      profileChanged: changed,
    );
  }
}
