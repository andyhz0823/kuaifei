import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/features/auth/notifier/auth_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AboutPage extends HookConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appInfo = ref.watch(appInfoProvider).requireValue;
    final auth = ref.watch(authNotifierProvider.notifier);
    final updateState = ref.watch(appUpdateNotifierProvider);
    final checkingUpdate = updateState is AppUpdateStateChecking;

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SelectableText(
                  appInfo.displayNameWithVersion,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  '请勿在中国大陆使用本应用',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.red),
                ),
                const SizedBox(height: 24),
                Text(
                  '警告：严禁观看、发布涉政不良内容，天网恢恢疏而不漏。',
                  textAlign: TextAlign.justify,
                  style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold, color: Colors.red),
                ),
                const SizedBox(height: 32),
                SelectableText(
                  '新购、续费地址：${auth.purchaseUrl}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                SelectableText(
                  '联系方式：${auth.contactEmail} ${auth.contactText}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: checkingUpdate
                      ? null
                      : () async {
                          final result = await ref.read(appUpdateNotifierProvider.notifier).check();
                          if (!context.mounted) return;

                          switch (result) {
                            case AppUpdateStateAvailable(:final versionInfo):
                              await ref
                                  .read(dialogNotifierProvider.notifier)
                                  .showNewVersion(
                                    currentVersion: appInfo.version,
                                    newVersion: versionInfo,
                                    canIgnore: false,
                                  );
                            case AppUpdateStateNotAvailable():
                              await ref
                                  .read(dialogNotifierProvider.notifier)
                                  .showOk('检查更新', '当前已是最新版本：v${appInfo.version}');
                            case AppUpdateStateDisabled():
                              await ref.read(dialogNotifierProvider.notifier).showOk('检查更新', '当前版本不支持远程更新检查');
                            case AppUpdateStateError():
                              await ref.read(dialogNotifierProvider.notifier).showOk('检查更新', '获取更新信息失败，请稍后重试');
                            default:
                              break;
                          }
                        },
                  icon: checkingUpdate
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.system_update_alt),
                  label: Text(checkingUpdate ? '正在检查更新' : '检查更新'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
