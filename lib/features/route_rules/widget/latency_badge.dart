import 'package:flutter/material.dart';
import 'package:hiddify/features/route_rules/data/available_outbounds_provider.dart';
import 'package:hiddify/features/route_rules/data/node_latency_provider.dart';

/// 统一的延迟展示：节点显示 ms（带颜色），策略组 / UDP 节点显示类型。
class LatencyBadge extends StatelessWidget {
  const LatencyBadge({super.key, required this.option, required this.latency});

  final OutboundOption option;

  /// null = 尚未测过；-1 = 超时/不可达；>=0 = 毫秒。
  final int? latency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (option.isGroup) {
      return Text(option.type, style: theme.textTheme.bodySmall);
    }
    if (!supportsLatencyProbe(option)) {
      return Text('${option.type} · —', style: theme.textTheme.bodySmall);
    }
    if (latency == null) {
      return Text('测速中…', style: theme.textTheme.bodySmall);
    }
    if (latency! < 0) {
      return Text('超时', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error));
    }
    final color = latency! <= 200
        ? const Color(0xFF2E7D32)
        : latency! <= 500
        ? const Color(0xFFEF6C00)
        : theme.colorScheme.error;
    return Text(
      '$latency ms',
      style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600),
    );
  }
}
