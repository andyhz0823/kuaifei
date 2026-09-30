import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/route_rules/data/rule_presets.dart';
import 'package:hiddify/features/route_rules/notifier/rule_notifier.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/route_rules/overview/rule_page.dart';
import 'package:hiddify/features/route_rules/widget/rule_tile.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class RulesPage extends HookConsumerWidget {
  const RulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final routeRuleT = t.pages.settings.routing.routeRule;
    final rules = ref.watch(rulesNotifierProvider);
    final menuItems = <PopupMenuEntry>[
      PopupMenuItem(
        onTap: () => _showPresets(context, ref),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome_rounded, size: 18),
            const Gap(8),
            Text(_presetTitle),
          ],
        ),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).importRulesFromClipboard,
        child: Text(routeRuleT.options.import.clipboard),
      ),
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).importRulesFromJsonFile,
        child: Text(routeRuleT.options.import.file),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        onTap: () async => await ref.read(rulesNotifierProvider.notifier).exportJsonToClipboard(),
        child: Text(routeRuleT.options.export.clipboard),
      ),
      PopupMenuItem(
        onTap: () async => await ref.read(rulesNotifierProvider.notifier).saveRulesAsJsonFile(),
        child: Text(routeRuleT.options.export.file),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).resetRules,
        child: Text(routeRuleT.options.reset),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(routeRuleT.title),
        actions: [
          PopupMenuButton(
            icon: const Icon(Icons.more_vert_rounded),
            // 列表为空时只保留「预设 / 导入」——没有规则可导出或重置
            itemBuilder: (_) => rules.isEmpty ? menuItems.getRange(0, 4).toList() : menuItems,
          ),
          const Gap(8),
        ],
      ),
      floatingActionButton: rules.isNotEmpty
          ? FloatingActionButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const RulePage())),
              child: const Icon(Icons.add_rounded),
            )
          : FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const RulePage())),
              label: Text(routeRuleT.createRule),
              icon: const Icon(Icons.add_rounded),
            ),
      body: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        onReorder: ref.read(rulesNotifierProvider.notifier).reorder,
        itemBuilder: (context, index) => RuleTile(key: Key('$index'), index: index, rule: rules[index]),
        itemCount: rules.length,
      ),
    );
  }

  /// 内置规则预设面板：点击即按当前语言落地成一条普通规则。
  ///
  /// 走 RulesNotifier.addRule，与手动创建的规则同构，用户可以照常编辑/排序/删除。
  Future<void> _showPresets(BuildContext context, WidgetRef ref) async {
    final t = ref.read(translationsProvider).requireValue;
    final routeRuleT = t.pages.settings.routing.routeRule;
    final existingNames = ref.read(rulesNotifierProvider).map((rule) => rule.name).toSet();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.75),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(routeRuleT.title, style: Theme.of(sheetContext).textTheme.titleMedium),
                    const Gap(4),
                    Text(_presetHint, style: Theme.of(sheetContext).textTheme.bodySmall),
                  ],
                ),
              ),
              for (final preset in kRouteRulePresets)
                ListTile(
                  leading: Icon(_iconFor(preset.outbound)),
                  title: Text(preset.name),
                  subtitle: Text(RuleEnum.outbound.present(t)),
                  trailing: existingNames.contains(preset.name) ? const Icon(Icons.check_rounded) : null,
                  onTap: () async {
                    final order = ref.read(rulesNotifierProvider).length;
                    await ref.read(rulesNotifierProvider.notifier).addRule(preset.toRule(order));
                    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                  },
                ),
              const Gap(12),
            ],
          ),
        ),
      ),
    );
  }

  /// 预设菜单项与面板标题。内置常量，理由同 RulePreset.name（避免 i18n 代码生成依赖）。
  static const _presetTitle = '规则预设';

  /// 预设面板说明文案。
  static const _presetHint = '一键添加常用分流规则，添加后仍可编辑、排序或删除';

  IconData _iconFor(Outbound outbound) => switch (outbound) {
    Outbound.proxy => Icons.vpn_lock_rounded,
    Outbound.direct => Icons.link_off_rounded,
    Outbound.direct_with_fragment => Icons.link_off_rounded,
    Outbound.block => Icons.block_rounded,
    _ => Icons.rule_rounded,
  };
}
