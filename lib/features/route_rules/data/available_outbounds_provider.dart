import 'dart:convert';

import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/route_rules/notifier/groups_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 分流规则里可选的「节点 / 策略组」。
///
/// 🔴 关键点：**不依赖 core 已连接**。
/// 之前这里用的是 `proxyRepository.watchActiveProxies()`，它走 core 的
/// GetOutbounds 流 —— 只有连上之后 core 才有 outbound 列表，用户断开状态下
/// 打开「指定节点 / 策略组」或「新建策略组」就只有一个永远转的圈，
/// 表现就是「没跳出节点列表，无法选择」。
///
/// 现在改为让 core 解析**激活订阅的配置文件**（generateConfig，不需要启动
/// 路由/连接），直接从 outbounds 里取 tag；再叠加用户自建策略组。
class OutboundOption {
  const OutboundOption({required this.tag, required this.type, this.host = '', this.port = 0, required this.isGroup});

  final String tag;
  final String type;

  /// 节点服务器地址（域名或 IP）。策略组没有该字段。
  final String host;

  /// 节点端口。策略组为 0。
  final int port;

  final bool isGroup;

  /// 只有真实节点（有 server + port）才做延迟探测。
  bool get canMeasure => !isGroup && host.isNotEmpty && port > 0;
}

/// core 内部出站与协议类型，不作为「可指定节点」展示。
const _systemTags = {'direct', 'block', 'dns-out', 'dns', 'bypass', 'block-out'};
const _systemTypes = {'direct', 'block', 'dns'};
const _groupTypes = {'selector', 'urltest', 'balancer'};

final availableOutboundsProvider = FutureProvider.autoDispose<List<OutboundOption>>((ref) async {
  final options = <OutboundOption>[];
  final seen = <String>{};

  void add(OutboundOption option) {
    if (option.tag.isEmpty || !seen.add(option.tag)) return;
    options.add(option);
  }

  // 1) 激活订阅的生成配置（未连接也能拿到节点 tag）
  try {
    final profile = await ref.watch(activeProfileProvider.future);
    if (profile != null) {
      final repo = await ref.watch(profileRepositoryProvider.future);
      final result = await repo.generateConfig(profile.id).run();
      result.fold((_) {}, (raw) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map || decoded['outbounds'] is! List) return;
        for (final item in decoded['outbounds'] as List) {
          if (item is! Map) continue;
          final tag = item['tag']?.toString() ?? '';
          final type = item['type']?.toString().toLowerCase() ?? '';
          if (tag.isEmpty || _systemTypes.contains(type)) continue;
          if (_systemTags.contains(tag.toLowerCase())) continue;
          final rawPort = item['server_port'];
          final port = rawPort is num ? rawPort.toInt() : int.tryParse(rawPort?.toString() ?? '') ?? 0;
          add(
            OutboundOption(
              tag: tag,
              type: type,
              host: item['server']?.toString() ?? '',
              port: port,
              isGroup: _groupTypes.contains(type),
            ),
          );
        }
      });
    }
  } catch (_) {
    // 解析失败时退回到「仅用户策略组」，至少不会卡在转圈上。
  }

  // 2) 用户自建策略组（可能还没写进配置文件，必须单独补上）
  for (final group in ref.watch(groupsNotifierProvider)) {
    add(OutboundOption(tag: group.name, type: group.type, isGroup: true));
  }

  return options;
});
