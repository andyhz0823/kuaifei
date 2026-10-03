import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/route_rules/data/outbound_options.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 当前订阅里可选的出站（策略组 + 真实节点），供规则绑定具体节点使用。
///
/// 数据来自 core 生成完整配置后的 outbounds —— 与真正生效的配置同一份来源，
/// 因此列表里有的节点一定是可解析到 outbounds 的，不会出现「选了但配不到」。
/// 没有激活订阅或生成失败时返回空集合，由选择页展示空态。
final outboundOptionsProvider = FutureProvider<OutboundOptions>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return OutboundOptions.empty;

  final repo = await ref.watch(profileRepositoryProvider.future);
  final config = await repo.generateConfig(profile.id).run();
  return config.match(
    (_) => OutboundOptions.empty,
    (json) => parseOutboundOptions(json),
  );
});
