import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/features/auth/notifier/auth_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AboutPage extends HookConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appInfo = ref.watch(appInfoProvider).requireValue;
    final auth = ref.watch(authNotifierProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
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
                '警告：严禁观看、发表涉政不良内容，天网恢恢疏而不漏。',
                textAlign: TextAlign.justify,
                style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold, color: Colors.red),
              ),
              const SizedBox(height: 4),
              Text(
                '警告：严禁观看、发表涉政不良内容，天网恢恢疏而不漏。',
                textAlign: TextAlign.justify,
                style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold, color: Colors.red),
              ),
              const SizedBox(height: 4),
              Text(
                '警告：严禁观看、发表涉政不良内容，天网恢恢疏而不漏。',
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
            ],
          ),
        ),
      ),
    );
  }
}
