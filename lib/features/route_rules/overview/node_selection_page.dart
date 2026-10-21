import 'package:flutter/material.dart';
import 'package:hiddify/features/route_rules/data/available_outbounds_provider.dart';
import 'package:hiddify/features/route_rules/data/node_latency_provider.dart';
import 'package:hiddify/features/route_rules/widget/latency_badge.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 从当前激活订阅里单选一个「节点」或「策略组」，用于「指定节点 / 策略组」分流。
///
/// 返回值为 `kind:tag` 形式的字符串（kind 为 `node` 或 `group`），
/// 由调用方写入规则的 ruleSets（`node:xxx` / `group:xxx` 前缀）。
///
/// 数据来自 [availableOutboundsProvider]（**未连接时也能列出节点**），
/// 延迟来自 [nodeLatencyProvider]（TCP 握手 RTT，不依赖 core 连接）。
class NodeSelectionPage extends ConsumerWidget {
  const NodeSelectionPage({super.key, this.selectedTag});

  /// 当前已选中的 tag（不含前缀），用于高亮。
  final String? selectedTag;

  static const nodePrefix = 'node:';
  static const groupPrefix = 'group:';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asyncOptions = ref.watch(availableOutboundsProvider);
    final testing = ref.watch(nodeLatencyProvider.select((state) => state.testing));
    final pending = ref.watch(nodeLatencyProvider.select((state) => state.pending));

    return Scaffold(
      appBar: AppBar(
        title: const Text('指定节点 / 策略组'),
        actions: [
          if (testing)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: Text('测速中 $pending', style: theme.textTheme.bodySmall)),
            )
          else
            IconButton(
              tooltip: '重新测速',
              icon: const Icon(Icons.speed),
              onPressed: () {
                final options = asyncOptions.asData?.value;
                if (options != null) {
                  ref.read(nodeLatencyProvider.notifier).measure(options, force: true);
                }
              },
            ),
        ],
      ),
      body: asyncOptions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载节点失败：$error')),
        data: (options) {
          if (options.isEmpty) {
            return const Center(
              child: Padding(padding: EdgeInsets.all(24), child: Text('暂无可用节点。请先在「订阅」页添加并激活一个配置，然后回到这里。')),
            );
          }
          // 首次进入自动测速；notifier 会跳过已有结果的节点，重复调用是空操作。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) ref.read(nodeLatencyProvider.notifier).measure(options);
          });
          return _buildList(context, ref, theme, options);
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, ThemeData theme, List<OutboundOption> options) {
    final groups = options.where((option) => option.isGroup).toList(growable: false);
    final nodes = options.where((option) => !option.isGroup).toList(growable: false);

    return ListView(
      children: [
        if (groups.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('策略组', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ),
          ...groups.map((g) => _tile(context, ref, groupPrefix, g)),
        ],
        if (nodes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('节点', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ),
          ...nodes.map((n) => _tile(context, ref, nodePrefix, n)),
        ],
      ],
    );
  }

  Widget _tile(BuildContext context, WidgetRef ref, String prefix, OutboundOption item) {
    final value = '$prefix${item.tag}';
    final isSelected = selectedTag == item.tag;
    final latency = ref.watch(nodeLatencyProvider.select((state) => state.results[item.tag]));
    return ListTile(
      leading: Icon(
        isSelected ? Icons.check_circle : Icons.circle_outlined,
        color: isSelected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(item.tag),
      subtitle: item.host.isNotEmpty ? Text(item.host, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
      trailing: LatencyBadge(option: item, latency: latency),
      onTap: () => Navigator.of(context).pop(value),
    );
  }
}
