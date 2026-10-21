import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 从当前激活订阅的 outbound 列表里单选一个「节点」或「策略组」，
/// 用于「指定节点 / 策略组」分流。
///
/// 返回值为 `kind:tag` 形式的字符串（kind 为 `node` 或 `group`），
/// 由调用方写入规则的 ruleSets（`node:xxx` / `group:xxx` 前缀）。
class NodeSelectionPage extends ConsumerWidget {
  const NodeSelectionPage({super.key, this.selectedTag});

  /// 当前已选中的 tag（不含前缀），用于高亮。
  final String? selectedTag;

  static const nodePrefix = 'node:';
  static const groupPrefix = 'group:';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final proxies = ref.watch(proxyRepositoryProvider).watchActiveProxies();

    return Scaffold(
      appBar: AppBar(
        title: const Text('指定节点 / 策略组'),
      ),
      body: StreamBuilder(
        stream: proxies,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return data.fold(
            (failure) => Center(child: Text('加载节点失败：$failure')),
            (groups) => _buildList(context, theme, groups),
          );
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, ThemeData theme, List<OutboundGroup> groups) {
    // 收集所有可见的节点（isGroup=false）与策略组（isGroup=true）。
    final nodes = <OutboundInfo>[];
    final outboundGroups = <OutboundInfo>[];
    final seen = <String>{};

    for (final group in groups) {
      for (final item in group.items) {
        if (!item.isVisible) continue;
        if (item.tag.isEmpty || !seen.add(item.tag)) continue;
        if (item.isGroup) {
          outboundGroups.add(item);
        } else {
          nodes.add(item);
        }
      }
    }

    if (nodes.isEmpty && outboundGroups.isEmpty) {
      return const Center(child: Text('暂无可用节点，请先连接订阅'));
    }

    return ListView(
      children: [
        if (outboundGroups.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('策略组', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ),
          ...outboundGroups.map((g) => _tile(context, groupPrefix, g)),
        ],
        if (nodes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('节点', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ),
          ...nodes.map((n) => _tile(context, nodePrefix, n)),
        ],
      ],
    );
  }

  Widget _tile(BuildContext context, String prefix, OutboundInfo item) {
    final displayName = item.tagDisplay.isNotEmpty ? item.tagDisplay : item.tag;
    final value = '$prefix${item.tag}';
    final isSelected = selectedTag == item.tag;
    return ListTile(
      leading: Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, color: isSelected ? Theme.of(context).colorScheme.primary : null),
      title: Text(displayName),
      subtitle: item.host.isNotEmpty ? Text(item.host, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
      trailing: Text(item.type, style: Theme.of(context).textTheme.bodySmall),
      onTap: () => Navigator.of(context).pop(value),
    );
  }
}
