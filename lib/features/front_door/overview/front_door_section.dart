import 'package:flutter/material.dart';
import 'package:hiddify/features/front_door/data/front_door_runner.dart';
import 'package:hiddify/features/front_door/model/front_door_candidate.dart';
import 'package:hiddify/features/front_door/overview/front_door_controller.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 路由设置页里的「节点自动优选」区块。
///
/// 文案沿用项目现状（直接写中文，不新增 slang 条目），避免动 translations 生成物。
class FrontDoorSection extends ConsumerWidget {
  const FrontDoorSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(FrontDoorPreferences.enabled);
    final state = ref.watch(frontDoorControllerProvider);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 24),
        SwitchListTile.adaptive(
          title: const Text('节点自动优选（吞吐测速）'),
          subtitle: const Text('订阅更新后在本机实测候选 IP 的下载吞吐，取最快 5 个复制成「优选1–5」节点；host 与 SNI 不变'),
          secondary: const Icon(Icons.speed_rounded),
          value: enabled,
          onChanged: ref.read(FrontDoorPreferences.enabled.notifier).update,
        ),
        ListTile(
          enabled: enabled,
          leading: const Icon(Icons.manage_search_rounded),
          title: const Text('优选匹配关键词'),
          subtitle: Text(
            ref.watch(FrontDoorPreferences.keywords).trim().isEmpty
                ? '未设置（不会命中任何节点）'
                : ref.watch(FrontDoorPreferences.keywords),
          ),
          onTap: () => _editText(
            context,
            title: '优选匹配关键词',
            hint: '多个关键词用逗号分隔；节点行（域名/备注）含任一关键词才参与优选',
            value: ref.read(FrontDoorPreferences.keywords),
            onSave: ref.read(FrontDoorPreferences.keywords.notifier).update,
          ),
        ),
        ListTile(
          enabled: enabled,
          leading: const Icon(Icons.cloud_download_rounded),
          title: const Text('cfst-ddns 优选源'),
          subtitle: Text(
            ref.watch(FrontDoorPreferences.source).trim().isEmpty
                ? '未配置：使用内置 CF 边缘 IP + 节点域名解析'
                : ref.watch(FrontDoorPreferences.source),
          ),
          onTap: () => _editText(
            context,
            title: 'cfst-ddns 优选源',
            hint: 'http(s) 地址，每行一个；支持纯 IP、ip:port、CloudflareST result.csv',
            value: ref.read(FrontDoorPreferences.source),
            onSave: ref.read(FrontDoorPreferences.source.notifier).update,
          ),
        ),
        ListTile(
          enabled: enabled,
          leading: const Icon(Icons.copy_all_rounded),
          title: const Text('克隆份数'),
          trailing: Text('${ref.watch(FrontDoorPreferences.copies)} 份'),
          onTap: () => _pickCopies(context, ref),
        ),
        ListTile(
          enabled: enabled,
          leading: Icon(state.busy ? Icons.hourglass_top_rounded : Icons.play_circle_outline_rounded),
          title: const Text('立即重新优选'),
          subtitle: Text(state.busy ? _phaseLabel(state) : '会重新下载订阅并测速，当前连接不会中断'),
          onTap: state.busy ? null : () => ref.read(frontDoorControllerProvider.notifier).run(force: true),
        ),
        if (state.busy)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(value: state.total > 1 ? state.progress : null),
          ),
        if (state.message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(state.message, style: theme.textTheme.bodySmall),
          ),
        if (state.best.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < state.best.length && i < 5; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '优选${i + 1}  ${state.best[i].candidate.host}'
                      '${state.best[i].mbps > 0 ? '  ${state.best[i].mbps.toStringAsFixed(1)} Mbps' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        if (state.status == FrontDoorStatus.done)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.bolt_rounded),
              label: const Text('立即应用（会断流约 2–5 秒）'),
              onPressed: () async {
                final ok = await ref.read(frontDoorControllerProvider.notifier).applyNow();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ok ? '正在重连以应用优选节点' : '重连失败，请手动切换节点')),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '测速在设备本地直连进行（不经过代理），视角即真实体验；结果缓存 6 小时，换网络自动失效。'
            '全部候选不可用时保留原节点，链路只会更好不会更差。',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  String _phaseLabel(FrontDoorState state) {
    if (state.status == FrontDoorStatus.fetching) return '正在获取候选…';
    if (state.status == FrontDoorStatus.writing) return '正在写入节点…';
    if (state.total > 1) return '正在测速 ${state.done}/${state.total}';
    return '正在测速…';
  }

  Future<void> _editText(
    BuildContext context, {
    required String title,
    required String hint,
    required String value,
    required Future<void> Function(String) onSave,
  }) async {
    final controller = TextEditingController(text: value);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: hint),
          minLines: 1,
          maxLines: 4,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    await onSave(result.trim());
  }

  Future<void> _pickCopies(BuildContext context, WidgetRef ref) async {
    final current = ref.read(FrontDoorPreferences.copies);
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('克隆份数'),
        children: [
          for (var i = 1; i <= 5; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(i),
              child: Row(
                children: [
                  Icon(i == current ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                  const SizedBox(width: 8),
                  Text('$i 份（优选1…优选$i）'),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(FrontDoorPreferences.copies.notifier).update(picked);
  }
}
