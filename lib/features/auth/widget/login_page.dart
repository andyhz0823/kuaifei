import 'package:flutter/material.dart';
import 'package:hiddify/features/auth/notifier/auth_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _panelUrlController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authNotifierProvider.notifier);
    _panelUrlController.text = auth.lastPanelUrl ?? '';
    _emailController.text = auth.lastEmail ?? '';
    _passwordController.text = auth.lastPassword ?? '';
  }

  @override
  void dispose() {
    _panelUrlController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    await ref
        .read(authNotifierProvider.notifier)
        .login(
          panelUrl: _panelUrlController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.vpn_lock_rounded, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 8),
                  Text(
                    'kuaifei',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '请登录您的账号',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _panelUrlController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '面板地址',
                      hintText: 'https://tttt.kuaifei.top',
                      helperText: '如果登录不上，请修改面板域名前缀为任意5位以上字母加数字组合，例如：https://kk44v.kuaifei.top',
                      helperMaxLines: 2,
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '请输入面板地址';
                      }
                      final url = value.trim();
                      if (!url.startsWith('http://') && !url.startsWith('https://')) {
                        return '面板地址需要以 http:// 或 https:// 开头';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: '邮箱',
                      hintText: 'your@email.com',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '请输入邮箱';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: '密码',
                      prefixIcon: const Icon(Icons.lock_outlined),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return '请输入密码';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => _handleLogin(),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: authState.isLoading ? null : _handleLogin,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: authState.isLoading
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              ),
                              SizedBox(width: 12),
                              Text('登录中...', style: TextStyle(fontSize: 16)),
                            ],
                          )
                        : const Text('登录', style: TextStyle(fontSize: 16)),
                  ),
                  const SizedBox(height: 8),
                  if (authState.isLoading)
                    TextButton(
                      onPressed: () {
                        ref.read(authNotifierProvider.notifier).cancelLogin();
                      },
                      child: const Text('取消', style: TextStyle(fontSize: 14)),
                    ),
                  if (authState.hasError)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _formatError(authState.error.toString()),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatError(String error) {
    // Clean up common verbose error messages
    if (error.contains('SocketException')) {
      final hostMatch = RegExp(r"Unable to connect to ([^\s:]+)").firstMatch(error);
      if (hostMatch != null) {
        final host = hostMatch.group(1);
        return '无法连接到 $host，请检查面板地址是否正确，或更换域名重试。';
      }
      return '网络连接失败，请检查面板地址或网络设置。';
    }
    if (error.contains('登录失败，请修改面板域名前缀')) {
      return '登录失败，请修改面板域名前缀为任意5位以上字母加数字组合，例如：https://kk44v.kuaifei.top';
    }
    if (error.contains('DioException')) {
      return '登录失败，请修改面板域名前缀为任意5位以上字母加数字组合，例如：https://kk44v.kuaifei.top';
    }
    if (error.contains('DoH failed')) {
      return 'DNS解析失败，请修改面板域名前缀为任意5位以上字母加数字组合，例如：https://kk44v.kuaifei.top';
    }
    if (error.contains('XMLHttpRequest')) {
      return '网络请求被拦截，请检查网络环境或更换面板地址。';
    }
    // Truncate very long errors
    if (error.length > 200) {
      return '${error.substring(0, 200)}...';
    }
    return error;
  }
}
