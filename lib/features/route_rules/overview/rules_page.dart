import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/route_rules/data/rule_presets.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/route_rules/overview/groups_page.dart';
import 'package:hiddify/features/route_rules/overview/rule_page.dart';
import 'package:hiddify/features/route_rules/widget/rule_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class RulesPage extends HookConsumerWidget {
  const RulesPage({super.key});

  void _showPresets(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final preset in RulePresets.presets)
                ListTile(
                  leading: const Icon(Icons.bolt_outlined),
                  title: Text(preset.title),
                  subtitle: Text(preset.description),
                  onTap: () {
                    ref.read(rulesNotifierProvider.notifier).addRules(preset.rules);
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final rules = ref.watch(rulesNotifierProvider);
    final menuItems = <PopupMenuEntry>[
      PopupMenuItem(
        onTap: () => _showPresets(context, ref),
        child: Text('导入预设规则'),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).importRulesFromClipboard,
        child: Text(t.pages.settings.routing.routeRule.options.import.clipboard),
      ),
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).importRulesFromJsonFile,
        child: Text(t.pages.settings.routing.routeRule.options.import.file),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        onTap: () async => await ref.read(rulesNotifierProvider.notifier).exportJsonToClipboard(),
        child: Text(t.pages.settings.routing.routeRule.options.export.clipboard),
      ),
      PopupMenuItem(
        onTap: () async => await ref.read(rulesNotifierProvider.notifier).saveRulesAsJsonFile(),
        child: Text(t.pages.settings.routing.routeRule.options.export.file),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        onTap: ref.read(rulesNotifierProvider.notifier).resetRules,
        child: Text(t.pages.settings.routing.routeRule.options.reset),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(t.pages.settings.routing.routeRule.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_tree_outlined),
            tooltip: '策略组',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GroupsPage())),
          ),
          PopupMenuButton(
            icon: const Icon(Icons.more_vert_rounded),
            itemBuilder: (_) => rules.isEmpty ? menuItems.getRange(0, 2).toList() : menuItems,
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
              label: Text(t.pages.settings.routing.routeRule.createRule),
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
}
