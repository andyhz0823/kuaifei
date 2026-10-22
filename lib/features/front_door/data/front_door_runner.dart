import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/front_door/data/front_door_service.dart';
import 'package:hiddify/features/front_door/data/node_cloner.dart';
import 'package:hiddify/features/front_door/model/front_door_candidate.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 优选功能设置（全部走 shared_preferences，无 DB 迁移）。
abstract final class FrontDoorPreferences {
  /// 总开关：关闭后订阅管道完全不执行优选（零开销）。
  static final enabled = PreferencesNotifier.create<bool, bool>('front-door-enabled', true);

  /// 匹配关键词，逗号/空格分隔；节点行（地址/host/SNI/备注）含任一即命中。
  static final keywords = PreferencesNotifier.create<String, String>('front-door-keywords', 'tkya.us.ci');

  /// cfst-ddns 输出地址，多个用换行/逗号分隔；留空则只用内置边缘 IP。
  static final source = PreferencesNotifier.create<String, String>('front-door-source', '');

  /// 克隆份数（1–5）。
  static final copies = PreferencesNotifier.create<int, int>('front-door-copies', 5);
}

/// 订阅管道与手动入口之间的一次性运行标志。
///
/// 订阅管道（`profile_parser`）无法感知 UI 的「强制刷新」意图，用静态标志传递，
/// 避免 runner 反过来依赖 controller / profile 模块造成循环依赖。
abstract final class FrontDoorRuntime {
  /// 下一次运行是否跳过缓存（手动「重新优选」置 true，消费后自动复位）。
  static bool forceNextRun = false;

  /// 最近一次运行结果（手动入口在 `upsertRemote` 之后取回它）。
  static FrontDoorOutcome? lastOutcome;
}

/// 订阅管道里的自动优选入口（**不依赖** controller，避免与 profile 模块循环依赖）。
///
/// [profilePath] 是订阅下载后、`validateConfig` 之前的临时文件（内容是已解码的
/// 明文 URI 行）。必须在这里改写：Go 的 `Parse` 之后 `configs/<id>.json` 变成
/// 编译后的 sing-box JSON，届时已找不到 `vless://` 行，也就无法保证
/// 选择器/策略组自动收录新节点。
Future<FrontDoorOutcome> runFrontDoor(
  Ref ref, {
  required String profilePath,
  bool force = false,
  void Function(String phase, int done, int total)? onProgress,
}) async {
  final forceNow = force || FrontDoorRuntime.forceNextRun;
  FrontDoorRuntime.forceNextRun = false;
  try {
    if (!ref.read(FrontDoorPreferences.enabled)) {
      const outcome = FrontDoorOutcome(status: FrontDoorStatus.skipped, message: '未开启节点优选');
      FrontDoorRuntime.lastOutcome = outcome;
      return outcome;
    }
    final keywords = NodeCloner.splitKeywords(ref.read(FrontDoorPreferences.keywords));
    if (keywords.isEmpty) {
      const outcome = FrontDoorOutcome(status: FrontDoorStatus.skipped, message: '未设置优选关键词');
      FrontDoorRuntime.lastOutcome = outcome;
      return outcome;
    }
    final preferences = ref.read(sharedPreferencesProvider).requireValue;
    final urls = ref
        .read(FrontDoorPreferences.source)
        .split(RegExp(r'[\s,;]+'))
        .map((e) => e.trim())
        .where((e) => e.startsWith('http'))
        .toList(growable: false);
    final copies = ref.read(FrontDoorPreferences.copies).clamp(1, 5);

    const service = FrontDoorService();
    final outcome = await service.run(
      profilePath: profilePath,
      preferences: preferences,
      keywords: keywords,
      sourceUrls: urls,
      copies: copies,
      forceRefresh: forceNow,
      onProgress: onProgress,
    );
    FrontDoorRuntime.lastOutcome = outcome;
    return outcome;
  } catch (_) {
    // 优选是增强功能，任何异常都不允许影响订阅更新主流程。
    const outcome = FrontDoorOutcome(status: FrontDoorStatus.failed, message: '优选执行异常（已跳过，不影响订阅）');
    FrontDoorRuntime.lastOutcome = outcome;
    return outcome;
  }
}
