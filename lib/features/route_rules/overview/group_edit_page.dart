import 'package:flutter/material.dart';
import 'package:hiddify/features/route_rules/data/available_outbounds_provider.dart';
import 'package:hiddify/features/route_rules/notifier/groups_notifier.dart';
import 'package:hiddify/singbox/model/singbox_group.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 新建 / 编辑一个用户自定义策略组。
class GroupEditPage extends ConsumerStatefulWidget {
  const GroupEditPage({super.key, this.index, this.initial});

  /// 编辑时的索引（新建为 null）。
  final int? index;
  final SingboxGroup? initial;

  @override
  ConsumerState<GroupEditPage> createState() => _GroupEditPageState();
}

class _GroupEditPageState extends ConsumerState<GroupEditPage> {
  late final TextEditingController _nameController;
  String _type = 'selector';
  final Set<String> _selectedNodes = {};

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _type = initial?.type ?? 'selector';
    _selectedNodes.addAll(initial?.outbounds ?? const []);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final group = SingboxGroup(name: name, type: _type, outbounds: _selectedNodes.toList());
    final notifier = ref.read(groupsNotifierProvider.notifier);
    if (widget.index != null) {
      notifier.updateGroup(widget.index!, group);
    } else {
      notifier.addGroup(group);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 不依赖 core 已连接：从激活订阅的生成配置里取节点，断开状态也能选。
    final asyncOptions = ref.watch(availableOutboundsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? '新建策略组' : '编辑策略组'),
        actions: [IconButton(onPressed: _save, icon: const Icon(Icons.check))],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '组名', hintText: '例如：香港节点', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text('类型', style: theme.textTheme.titleSmall),
                    const SizedBox(width: 16),
                    ChoiceChip(
                      label: const Text('手动选择 (selector)'),
                      selected: _type == 'selector',
                      onSelected: (_) => setState(() => _type = 'selector'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('自动测速 (urltest)'),
                      selected: _type == 'urltest',
                      onSelected: (_) => setState(() => _type = 'urltest'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: asyncOptions.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('加载节点失败：$error')),
              data: (options) => _buildNodes(context, options),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNodes(BuildContext context, List<OutboundOption> options) {
    // 策略组只能由真实节点组成，不能再嵌套策略组。
    final nodes = options.where((option) => !option.isGroup).toList(growable: false);

    if (nodes.isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('暂无可用节点。请先在「订阅」页添加并激活一个配置，然后回到这里。')),
      );
    }

    return ListView.builder(
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        final node = nodes[index];
        return CheckboxListTile(
          title: Text(node.tag),
          subtitle: node.host.isNotEmpty ? Text(node.host, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
          value: _selectedNodes.contains(node.tag),
          onChanged: (checked) {
            setState(() {
              if (checked == true) {
                _selectedNodes.add(node.tag);
              } else {
                _selectedNodes.remove(node.tag);
              }
            });
          },
        );
      },
    );
  }
}
