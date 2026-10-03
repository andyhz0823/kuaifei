import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/route_rules/data/outbound_options.dart';
import 'package:hiddify/features/route_rules/notifier/outbound_options_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 出站选择器：给规则绑定一个具体节点或策略组（select/lowest/balance）。
///
/// 文案用内置常量而非 i18n：新增 i18n key 需要重新生成 slang 产物（lib/gen 下多个文件），
/// 对这条链路是不必要的耦合（与 rule_presets.dart 的处理保持一致）。
class OutboundPickerPage extends HookConsumerWidget {
  const OutboundPickerPage({super.key, required this.currentTag});

  /// 当前已绑定的 tag；为空表示未指定（走规则里的默认出站枚举）。
  final String currentTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncOptions = ref.watch(outboundOptionsProvider);
    final keyword = useState('');
    final controller = useTextEditingController();

    bool matches(OutboundOption option) {
      final q = keyword.value.trim().toLowerCase();
      if (q.isEmpty) return true;
      return option.name.toLowerCase().contains(q) || option.tag.toLowerCase().contains(q);
    }

    Widget section(String title, IconData icon, List<OutboundOption> items) {
      final visible = items.where(matches).toList();
      if (visible.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(title, style: Theme.of(context).textTheme.labelLarge),
          ),
          ...visible.map(
            (option) => RadioListTile<String>(
              value: option.tag,
              groupValue: currentTag,
              onChanged: (value) => Navigator.of(context).pop(value),
              title: Text(option.name, style: Theme.of(context).textTheme.bodyMedium),
              secondary: Icon(icon),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('选择出站节点'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新节点列表',
            onPressed: () => ref.invalidate(outboundOptionsProvider),
          ),
        ],
      ),
      body: asyncOptions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('读取节点列表失败：$error'),
          ),
        ),
        data: (options) {
          if (options.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂无可选节点。请先在首页添加订阅，成功连接一次后再来绑定。'),
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '选中后，本条规则的流量将走该节点，优先级高于「默认出站」。'
                  '节点来自订阅，订阅变化后若节点消失，该规则会自动回退到主出口。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: '搜索节点',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: keyword.value.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              controller.clear();
                              keyword.value = '';
                            },
                          ),
                  ),
                  onChanged: (value) => keyword.value = value,
                ),
              ),
              RadioListTile<String>(
                value: '',
                groupValue: currentTag,
                onChanged: (value) => Navigator.of(context).pop(value),
                title: const Text('不指定（使用默认出站）'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: [
                    section('策略组', Icons.hub_outlined, options.groups),
                    section('节点', Icons.dns_outlined, options.nodes),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
