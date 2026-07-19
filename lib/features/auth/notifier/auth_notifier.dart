import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/db/provider/db_providers.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/auth/data/xboard_api_client.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

enum AuthStatus { idle, loading, authenticated, error }

final authNotifierProvider = AsyncNotifierProvider<AuthNotifier, AuthStatus>(() => AuthNotifier());

class AuthNotifier extends AsyncNotifier<AuthStatus> with AppLogger {
  static const _loginTimeout = Duration(seconds: 30);
  static const _loginTimeoutMessage = '登录失败，请修改面板域名前缀为任意5位以上字母加数字组合，例如：https://kk44v.kuaifei.top';
  static const _defaultPurchaseUrl = 'https://*.kuaifei.top(*换为任意字母或数字，APP登录不上也换为这类地址即可)';
  static const _legacyPurchaseUrl = 'https://kuaifei.top';
  static const _defaultContactEmail = 'wahiya562@gmail.com';
  static const _legacyContactEmail = 'mahiya562@gmail.com';

  @override
  Future<AuthStatus> build() async {
    // Don't auto-login on startup — show the login page, let user click login
    return AuthStatus.idle;
  }

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider).requireValue;

  String? _readPanelUrl() => _prefs.getString('auth_panel_url');
  String? _readSanctumToken() => _prefs.getString('auth_sanctum_token');
  String? _readSubscriptionToken() => _prefs.getString('auth_subscription_token');
  String? _readSubscribeUrl() => _prefs.getString('auth_subscribe_url');
  String? _readSubscribeProfiles() => _prefs.getString('auth_subscribe_profiles');
  String? _readEmail() => _prefs.getString('auth_email');

  String? get panelUrl => _readPanelUrl();
  String? get email => _readEmail();
  String? get sanctumToken => _readSanctumToken();
  String? get subscriptionToken => _readSubscriptionToken();

  String? get lastPanelUrl => _prefs.getString('auth_last_panel_url') ?? _readPanelUrl();
  String? get lastEmail => _prefs.getString('auth_last_email') ?? _readEmail();
  String? get lastPassword => _prefs.getString('auth_last_password');

  String get purchaseUrl => _normalizePurchaseUrl(_prefs.getString('auth_purchase_url'));
  String get contactEmail => _normalizeContactEmail(_prefs.getString('auth_contact_email'));
  String get contactText => _prefs.getString('auth_contact_text') ?? '24小时内回复';

  String _normalizePurchaseUrl(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty || normalized == _legacyPurchaseUrl) {
      return _defaultPurchaseUrl;
    }
    return normalized;
  }

  String _normalizeContactEmail(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty || normalized.toLowerCase() == _legacyContactEmail) {
      return _defaultContactEmail;
    }
    return normalized;
  }

  Future<void> _writePreference(String key, String value) async {
    await _prefs.setString(key, value);
  }

  Future<void> _removePreference(String key) async {
    await _prefs.remove(key);
  }

  Future<void> login({required String panelUrl, required String email, required String password}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final normalizedUrl = panelUrl.replaceAll(RegExp(r'/+$'), '');
      await _rememberLastLoginInput(panelUrl: normalizedUrl, email: email, password: password);

      final client = XboardApiClient(baseUrl: normalizedUrl);

      loggy.debug('Auth: logging in to $normalizedUrl as $email');
      final (:loginResult, :subscribeResult) = await (() async {
        await client.prewarm();
        final loginResult = await client.login(email: email, password: password);
        client.setToken(loginResult.sanctumToken);
        final subscribeResult = await client.getSubscribe();
        return (loginResult: loginResult, subscribeResult: subscribeResult);
      })().timeout(_loginTimeout, onTimeout: () => throw XboardApiException(_loginTimeoutMessage));

      await _writePreference('auth_panel_url', normalizedUrl);
      await _writePreference('auth_sanctum_token', loginResult.sanctumToken);
      await _writePreference('auth_subscription_token', loginResult.subscriptionToken);
      await _writePreference('auth_email', email);
      await _persistSubscribeResult(subscribeResult);

      if (subscriptionProfiles.isEmpty) {
        await clearLocalProfileData();
        ref.invalidate(activeProfileProvider);
        loggy.info('Auth: no usable subscriptions; local profiles cleared');
      } else {
        try {
          await _syncStoredSubscriptionsToProfiles(removeObsoleteProfiles: true, throwOnTotalFailure: true);
        } catch (e, st) {
          loggy.warning('Auth: subscription import failed, but login succeeded', e, st);
        }
      }

      loggy.debug('Auth: login successful for $email');
      return AuthStatus.authenticated;
    });
  }

  Future<void> cancelLogin() {
    state = const AsyncData(AuthStatus.idle);
    return Future.value();
  }

  Future<void> _rememberLastLoginInput({
    required String panelUrl,
    required String email,
    required String password,
  }) async {
    await _writePreference('auth_last_panel_url', panelUrl);
    await _writePreference('auth_last_email', email);
    await _writePreference('auth_last_password', password);
  }

  Future<void> _persistSubscribeResult(XboardSubscribeResult subscribeResult) async {
    if (subscribeResult.subscribeUrl.isNotEmpty) {
      await _writePreference('auth_subscribe_url', subscribeResult.subscribeUrl);
    }

    final profiles =
        (subscribeResult.subscriptions.isNotEmpty
                ? subscribeResult.subscriptions
                : [
                    if (subscribeResult.subscribeUrl.isNotEmpty)
                      XboardSubscriptionProfile(subscribeUrl: subscribeResult.subscribeUrl),
                  ])
            .where((profile) => profile.isUsable)
            .toList(growable: false);
    await _writePreference('auth_subscribe_profiles', jsonEncode(profiles.map((item) => item.toJson()).toList()));

    final appConfig = subscribeResult.appConfig;
    await _writePreference('auth_purchase_url', _normalizePurchaseUrl(appConfig.purchaseUrl));
    await _writePreference('auth_contact_email', _normalizeContactEmail(appConfig.contactEmail));
    if (appConfig.contactText?.isNotEmpty == true) {
      await _writePreference('auth_contact_text', appConfig.contactText!);
    }
  }

  String? get subscribeUrl {
    final savedUrl = _readSubscribeUrl();
    if (savedUrl != null && savedUrl.isNotEmpty) return savedUrl;

    final panelUrl = _readPanelUrl();
    final token = _readSubscriptionToken();
    if (panelUrl == null || token == null) return null;
    return '$panelUrl/s/$token';
  }

  List<XboardSubscriptionProfile> get subscriptionProfiles {
    final rawProfiles = _readSubscribeProfiles();
    if (rawProfiles != null && rawProfiles.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawProfiles);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((item) => XboardSubscriptionProfile.fromJson(Map<String, dynamic>.from(item)))
              .where((item) => item.subscribeUrl.isNotEmpty)
              .toList(growable: false);
        }
      } catch (e, st) {
        loggy.warning('Failed to parse saved subscribe profiles', e, st);
      }
    }

    final fallbackUrl = subscribeUrl;
    if (fallbackUrl == null || fallbackUrl.isEmpty) return const [];
    return [XboardSubscriptionProfile(subscribeUrl: fallbackUrl)];
  }

  Future<void> _syncStoredSubscriptionsToProfiles({
    bool removeObsoleteProfiles = false,
    bool throwOnTotalFailure = false,
  }) async {
    final profiles = subscriptionProfiles;
    if (profiles.isEmpty) return;

    final repo = await ref.read(profileRepositoryProvider.future);
    final db = ref.read(dbProvider);
    final desiredUrls = profiles.map((profile) => profile.subscribeUrl).where((url) => url.isNotEmpty).toSet();

    loggy.info('Auth: importing ${profiles.length} subscriptions as separate profiles');
    var successCount = 0;
    final successfulUrls = <String>{};
    Object? lastFailure;
    for (final profile in profiles) {
      final url = profile.subscribeUrl;
      if (url.isEmpty) continue;

      final profileName = (profile.name != null && profile.name!.isNotEmpty) ? profile.name! : null;

      try {
        final result = await repo
            .upsertRemote(url, userOverride: profileName != null ? UserOverride(name: profileName) : null)
            .run();

        switch (result) {
          case Left(value: final failure):
            lastFailure = failure;
            loggy.warning('Auth: failed to sync subscription from $url', failure);
          case Right():
            successCount++;
            successfulUrls.add(url);
            await _applySubscriptionInfo(profile);
            loggy.info('Auth: synced profile "$profileName" from $url');
        }
      } catch (e, st) {
        lastFailure = e;
        loggy.warning('Auth: failed to process subscription $url', e, st);
      }
    }

    if (throwOnTotalFailure && successCount == 0) {
      throw StateError('Failed to sync any subscription profile: $lastFailure');
    }

    if (successfulUrls.isNotEmpty) {
      await _activateSyncedProfile(repo, db, profiles, successfulUrls);

      if (removeObsoleteProfiles && successfulUrls.length == desiredUrls.length) {
        await _removeObsoleteProfiles(repo, db, desiredUrls);
      }

      // A keep-alive StreamProvider can still expose the profile that was active
      // before login until its database stream emits. Rebuild it from the final DB state.
      ref.invalidate(activeProfileProvider);
    }

    loggy.info('Auth: successfully synced $successCount subscription profiles');
  }

  Future<void> _activateSyncedProfile(
    ProfileRepository repo,
    Db db,
    List<XboardSubscriptionProfile> profiles,
    Set<String> successfulUrls,
  ) async {
    final entries = await db.select(db.profileEntries).get();

    ProfileEntry? selected;
    for (final entry in entries) {
      if (entry.active && entry.url != null && successfulUrls.contains(entry.url)) {
        selected = entry;
        break;
      }
    }

    if (selected == null) {
      for (final profile in profiles) {
        if (!successfulUrls.contains(profile.subscribeUrl)) continue;
        for (final entry in entries) {
          if (entry.url == profile.subscribeUrl) {
            selected = entry;
            break;
          }
        }
        if (selected != null) break;
      }
    }

    if (selected == null || selected.active) return;

    final result = await repo.setAsActive(selected.id).run();
    result.match(
      (failure) => throw StateError('Failed to activate synced profile ${selected!.id}: $failure'),
      (_) => loggy.info('Auth: activated synced profile ${selected!.id}'),
    );
  }

  Future<void> _removeObsoleteProfiles(ProfileRepository repo, Db db, Set<String> desiredUrls) async {
    final entries = await db.select(db.profileEntries).get();
    for (final entry in entries) {
      if (entry.url != null && desiredUrls.contains(entry.url)) continue;

      final result = await repo.deleteById(entry.id, entry.active).run();
      result.match(
        (failure) => loggy.warning('Auth: failed to remove obsolete profile ${entry.id}', failure),
        (_) => loggy.info('Auth: removed obsolete profile ${entry.id}'),
      );
    }
  }

  /// Downloads subscription content via HTTP.
  Future<void> _applySubscriptionInfo(XboardSubscriptionProfile profile) async {
    if (!profile.hasSubscriptionInfo) return;

    final expire = profile.expireDate;
    if (expire == null) return;

    final db = ref.read(dbProvider);
    final entry = await (db.select(
      db.profileEntries,
    )..where((tbl) => tbl.url.equals(profile.subscribeUrl))).getSingleOrNull();
    if (entry == null) return;

    await (db.update(db.profileEntries)..where((tbl) => tbl.id.equals(entry.id))).write(
      ProfileEntriesCompanion(
        upload: Value(profile.upload ?? entry.upload ?? 0),
        download: Value(profile.download ?? entry.download ?? 0),
        total: Value(profile.total),
        expire: Value(expire),
      ),
    );
  }

  Future<void> clearLocalProfileData() async {
    try {
      final dirs = ref.read(appDirectoriesProvider).requireValue;
      final configsDir = Directory(p.join(dirs.workingDir.path, 'configs'));
      if (await configsDir.exists()) {
        await configsDir.delete(recursive: true);
      }

      final db = ref.read(dbProvider);
      await db.delete(db.profileEntries).go();
      await db.delete(db.appProxyEntries).go();
    } catch (e, st) {
      loggy.warning('Failed to clean up profile data', e, st);
    }
  }

  Future<void> logout() async {
    await _removePreference('auth_panel_url');
    await _removePreference('auth_sanctum_token');
    await _removePreference('auth_subscription_token');
    await _removePreference('auth_subscribe_url');
    await _removePreference('auth_subscribe_profiles');
    await _removePreference('auth_email');

    await clearLocalProfileData();

    state = const AsyncData(AuthStatus.idle);
    loggy.debug('Auth: logged out, credentials and configs cleared');
  }
}
