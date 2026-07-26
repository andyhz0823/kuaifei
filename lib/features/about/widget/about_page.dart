import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/features/auth/notifier/auth_notifier.dart';
import 'package:hiddify/utils/uri_utils.dart';
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
      appBar: AppBar(title: const Text('\u5173\u4e8e')),
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
                  '\u8bf7\u52ff\u5728\u4e2d\u56fd\u5927\u9646\u4f7f\u7528\u672c\u5e94\u7528',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.red),
                ),
                const SizedBox(height: 24),
                Text(
                  '\u8b66\u544a\uff1a\u4e25\u7981\u89c2\u770b\u3001\u53d1\u5e03\u6d89\u653f\u53ca\u4e0d\u826f\u5185\u5bb9\uff0c\u5929\u7f51\u6062\u590d\u758f\u800c\u4e0d\u6f0f\u3002',
                  textAlign: TextAlign.justify,
                  style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold, color: Colors.red),
                ),
                const SizedBox(height: 32),
                SelectableText(
                  '\u65b0\u8d2d\u3001\u7eed\u8d39\u5730\u5740\uff1a${auth.purchaseUrl}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                SelectableText(
                  '\u8054\u7cfb\u65b9\u5f0f\uff1a${auth.contactEmail} ${auth.contactText}',
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
                                  .showOk(
                                    '\u68c0\u67e5\u66f4\u65b0',
                                    '\u5f53\u524d\u5df2\u662f\u6700\u65b0\u7248\u672c\uff1av${appInfo.version}',
                                  );
                            case AppUpdateStateDisabled():
                              await ref
                                  .read(dialogNotifierProvider.notifier)
                                  .showOk(
                                    '\u68c0\u67e5\u66f4\u65b0',
                                    '\u5f53\u524d\u7248\u672c\u4e0d\u652f\u6301\u8fdc\u7a0b\u66f4\u65b0\u68c0\u67e5',
                                  );
                            case AppUpdateStateError():
                              await ref
                                  .read(dialogNotifierProvider.notifier)
                                  .showOk(
                                    '\u68c0\u67e5\u66f4\u65b0',
                                    '\u83b7\u53d6\u66f4\u65b0\u4fe1\u606f\u5931\u8d25\uff0c\u8bf7\u7a0d\u540e\u91cd\u8bd5',
                                  );
                            default:
                              break;
                          }
                        },
                  icon: checkingUpdate
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.system_update_alt),
                  label: Text(checkingUpdate ? '\u6b63\u5728\u68c0\u67e5\u66f4\u65b0' : '\u68c0\u67e5\u66f4\u65b0'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.purchaseUrl)),
                  icon: const Icon(Icons.shopping_cart_outlined),
                  label: const Text('\u8ba2\u9605\u3001\u7eed\u8d39\u8d2d\u4e70'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
