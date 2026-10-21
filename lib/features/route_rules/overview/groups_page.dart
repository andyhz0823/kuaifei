import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/features/route_rules/notifier/groups_notifier.dart';
import 'package:hiddify/features/route_rules/overview/group_edit_page.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 用户自定义策略组列表页。
class GroupsPage extends ConsumerWidget {
  const GroupsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsNotifierProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('策略组')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GroupEditPage())),
        label: const Text('新建策略组'),
        icon: const Icon(Icons.add_rounded),
      ),
      body: groups.isEmpty
          ? const Center(child: Text('暂无策略组。策略组可把多个节点组成一组，供分流规则指向。'))
          : ListView.builder(
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                return ListTile(
                  leading: Icon(group.type == 'urltest' ? Icons.speed : Icons.account_tree_outlined),
                  title: Text(group.name),
                  subtitle: Text('${group.type == 'urltest' ? '自动测速' : '手动选择'} · ${group.outbounds.length} 个节点'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => GroupEditPage(index: index, initial: group)),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                        onPressed: () => ref.read(groupsNotifierProvider.notifier).deleteGroup(index),
                      ),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => GroupEditPage(index: index, initial: group)),
                  ),
                );
              },
            ),
    );
  }
}
