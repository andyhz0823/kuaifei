import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/front_door/data/front_door_runner.dart';
import 'package:hiddify/features/front_door/model/front_door_candidate.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 优选任务对外状态（UI 订阅）。
class FrontDoorState {
  const FrontDoorState({
    this.status = FrontDoorStatus.idle,
    this.message = '',
    this.done = 0,
    this.total = 0,
    this.best = const [],
    this.bytes = 0,
  });

  final FrontDoorStatus status;
  final String message;
  final int done;
  final int total;
  final List<ProbeResult> best;
  final int bytes;

  bool get busy =>
      status == FrontDoorStatus.fetching || status == FrontDoorStatus.probing || status == FrontDoorStatus.writing;

  double get progress => total <= 0 ? 0 : (done / total).clamp(0, 1).toDouble();

  FrontDoorState copyWith({
    FrontDoorStatus? status,
    String? message,
    int? done,
    int? total,
    List<ProbeResult>? best,
    int? bytes,
  }) {
    return FrontDoorState(
      status: status ?? this.status,
      message: message ?? this.message,
      done: done ?? this.done,
      total: total ?? this.total,
      best: best ?? this.best,
      bytes: bytes ?? this.bytes,
    );
  }
}

final frontDoorControllerProvider = NotifierProvider<FrontDoorController, FrontDoorState>(FrontDoorController.new);

/// 手动触发优选。
///
/// 为什么手动入口要「重新下载订阅」而不是直接改 `configs/<id>.json`：
/// 那个文件是 Go 编译后的 sing-box JSON，节点已不是 `vless://` 行；
/// 只有重走一遍订阅管道，克隆出来的节点才会被选择器/策略组自动收录。
/// `upsertRemote` **只写文件、不重启 core**（本项目无热重载），
/// 所以重新优选不会打断当前连接 —— 与自动路径的行为一致。
class FrontDoorController extends Notifier<FrontDoorState> with InfraLogger {
  bool _running = false;

  @override
  FrontDoorState build() => const FrontDoorState();

  Future<void> run({bool force = true}) async {
    if (_running) return;
    _running = true;
    state = state.copyWith(status: FrontDoorStatus.fetching, message: '准备中…', done: 0, total: 1);
    try {
      final active = await ref.read(activeProfileProvider.future);
      if (active == null) {
        state = const FrontDoorState(status: FrontDoorStatus.skipped, message: '请先登录并添加订阅');
        return;
      }
      // 只有远程订阅才能「重新下载 → 重新优选」；本地导入的配置没有 url。
      if (active is! RemoteProfileEntity) {
        state = const FrontDoorState(
          status: FrontDoorStatus.skipped,
          message: '本地导入的配置不支持重新优选，请使用订阅',
        );
        return;
      }
      final url = active.url;

      FrontDoorRuntime.forceNextRun = force;
      FrontDoorRuntime.lastOutcome = null;

      // upsertRemote 只写文件、不重启 core（本项目无热重载），所以重新优选
      // 不会打断当前连接；克隆节点在下次连接时生效。
      final result = await ref.read(profileRepositoryProvider).requireValue.upsertRemote(url).run();
      result.match(
        (failure) => loggy.warning('front-door: upsertRemote failed: $failure'),
        (_) {},
      );

      final outcome = FrontDoorRuntime.lastOutcome;
      if (outcome == null) {
        state = const FrontDoorState(status: FrontDoorStatus.failed, message: '优选未执行（检查是否已开启）');
        return;
      }
      state = FrontDoorState(
        status: outcome.status,
        message: outcome.summary,
        done: 1,
        total: 1,
        best: outcome.best,
        bytes: outcome.bytes,
      );
      loggy.info('front-door: manual run -> ${outcome.summary}');
    } catch (err, st) {
      loggy.warning('front-door: manual run failed', err, st);
      state = const FrontDoorState(status: FrontDoorStatus.failed, message: '优选失败，请稍后重试');
    } finally {
      _running = false;
    }
  }

  /// 立即应用（**会断流约 2–5 秒**，故只由用户显式点击触发，决策 D3=A）。
  Future<bool> applyNow() async {
    try {
      final profile = await ref.read(activeProfileProvider.future);
      if (profile == null) return false;
      await ref.read(connectionNotifierProvider.notifier).reconnect(profile);
      return true;
    } catch (err, st) {
      loggy.warning('front-door: apply failed', err, st);
      return false;
    }
  }

  /// 清空缓存（下次会重新测速）。
  Future<void> clearCache() async {
    final prefs = ref.read(sharedPreferencesProvider).requireValue;
    await prefs.remove('front_door_cache_v1');
    state = const FrontDoorState(status: FrontDoorStatus.idle, message: '已清除优选缓存');
  }
}
