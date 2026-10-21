import 'dart:convert';

import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/singbox/model/singbox_group.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'groups_notifier.g.dart';

/// 用户自定义策略组（分流规则可指向组名）。
/// 持久化到 SharedPreferences 的 `route_groups`（JSON 字符串）。
@riverpod
class GroupsNotifier extends _$GroupsNotifier {
  static const _prefKey = 'route_groups';

  @override
  List<SingboxGroup> build() {
    final raw = ref.watch(sharedPreferencesProvider).requireValue.getString(_prefKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((item) => SingboxGroup.fromJson(Map<String, dynamic>.from(item)))
            .where((group) => group.name.trim().isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {
      // 损坏的缓存被忽略，下次保存会覆盖。
    }
    return [];
  }

  Future<void> addGroup(SingboxGroup group) async {
    state = [...state, group];
    await _persist();
  }

  Future<void> updateGroup(int index, SingboxGroup group) async {
    final current = [...state];
    if (index < 0 || index >= current.length) return;
    current[index] = group;
    state = current;
    await _persist();
  }

  Future<void> deleteGroup(int index) async {
    final current = [...state];
    if (index < 0 || index >= current.length) return;
    current.removeAt(index);
    state = current;
    await _persist();
  }

  Future<void> _persist() async {
    final encoded = jsonEncode(state.map((group) => group.toJson()).toList(growable: false));
    await ref.read(sharedPreferencesProvider).requireValue.setString(_prefKey, encoded);
  }
}
