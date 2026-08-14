import 'package:drift/drift.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:loggy/loggy.dart';

part 'profile_data_source.g.dart';

abstract interface class ProfileDataSource {
  Future<ProfileEntry?> getById(String id);
  Future<ProfileEntry?> getByUrl(String url);
  Future<ProfileEntry?> getByName(String name);
  Future<ProfileEntry?> getRemoteByName(String name);
  Future<void> deleteRemoteDuplicatesByName(String name, {required String keepId});
  Stream<ProfileEntry?> watchActiveProfile();
  Stream<int> watchProfilesCount();
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode});
  Future<void> insert(ProfileEntriesCompanion entry);
  Future<void> edit(String id, ProfileEntriesCompanion entry);
  Future<void> deleteById(String id, bool isActive);
}

Map<SortMode, OrderingMode> orderMap = {SortMode.ascending: OrderingMode.asc, SortMode.descending: OrderingMode.desc};

@DriftAccessor(tables: [ProfileEntries])
class ProfileDao extends DatabaseAccessor<Db> with _$ProfileDaoMixin, InfraLogger implements ProfileDataSource {
  ProfileDao(super.db);

  @override
  Future<ProfileEntry?> getById(String id) async {
    return await (profileEntries.select()..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
  }

  @override
  Future<ProfileEntry?> getByUrl(String url) async {
    return await (select(profileEntries)
          ..where((tbl) => tbl.url.like('%$url%'))
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Future<ProfileEntry?> getByName(String name) async {
    return await (select(profileEntries)
          ..where((tbl) => tbl.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Future<ProfileEntry?> getRemoteByName(String name) async {
    final exact =
        await (select(profileEntries)
              ..where((tbl) => tbl.name.equals(name) & tbl.type.equalsValue(ProfileType.remote))
              ..orderBy([(tbl) => OrderingTerm(expression: tbl.lastUpdate, mode: OrderingMode.desc)])
              ..limit(1))
            .getSingleOrNull();
    if (exact != null) return exact;

    final candidates =
        await (select(profileEntries)
              ..where((tbl) => tbl.name.like('$name%') & tbl.type.equalsValue(ProfileType.remote))
              ..orderBy([(tbl) => OrderingTerm(expression: tbl.lastUpdate, mode: OrderingMode.desc)]))
            .get();
    for (final entry in candidates) {
      if (_isGeneratedDuplicateName(name, entry.name)) return entry;
    }
    return null;
  }

  @override
  Future<void> deleteRemoteDuplicatesByName(String name, {required String keepId}) async {
    final candidates =
        await (select(profileEntries)..where(
              (tbl) => tbl.name.like('$name%') & tbl.type.equalsValue(ProfileType.remote) & tbl.id.equals(keepId).not(),
            ))
            .get();
    final duplicateIds = candidates
        .where((entry) => _isGeneratedDuplicateName(name, entry.name))
        .map((entry) => entry.id)
        .toList(growable: false);
    for (final id in duplicateIds) {
      await (delete(profileEntries)..where((tbl) => tbl.id.equals(id))).go();
    }
  }

  bool _isGeneratedDuplicateName(String baseName, String candidate) {
    if (candidate == baseName) return true;
    if (!candidate.startsWith(baseName)) return false;
    final suffix = candidate.substring(baseName.length);
    return suffix.isNotEmpty && int.tryParse(suffix) != null;
  }

  @override
  Stream<ProfileEntry?> watchActiveProfile() {
    return (profileEntries.select()
          ..where((tbl) => tbl.active.equals(true))
          ..limit(1))
        .watchSingleOrNull()
        .distinct();
  }

  @override
  Stream<int> watchProfilesCount() {
    final count = profileEntries.id.count();
    return (profileEntries.selectOnly()..addColumns([count])).map((exp) => exp.read(count)!).watchSingle().distinct();
  }

  @override
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode}) {
    return (profileEntries.select()..orderBy([
          (tbl) => OrderingTerm(expression: tbl.active, mode: OrderingMode.desc),
          (tbl) {
            final trafficRatio = (tbl.download + tbl.upload) / tbl.total;
            final isExpired = tbl.expire.isSmallerOrEqualValue(DateTime.now());
            return OrderingTerm(
              expression:
                  (trafficRatio.isNull() | trafficRatio.isSmallerThanValue(1)) &
                  (isExpired.isNull() | isExpired.equals(false)),
              mode: OrderingMode.desc,
            );
          },
          switch (sort) {
            ProfilesSort.name => (tbl) => OrderingTerm(expression: tbl.name, mode: orderMap[sortMode]!),
            ProfilesSort.lastUpdate => (tbl) => OrderingTerm(expression: tbl.lastUpdate, mode: orderMap[sortMode]!),
          },
        ]))
        .watch();
  }

  @override
  Future<void> insert(ProfileEntriesCompanion entry) async {
    await transaction(() async {
      if (entry.active.present && entry.active.value) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      final name = StringBuffer(entry.name.value);
      while (await getByName(name.toString()) != null) {
        name.write('${randomInt(0, 9).run()}');
      }
      await into(profileEntries).insert(entry.copyWith(name: Value(name.toString())));
    });
  }

  @override
  Future<void> edit(String id, ProfileEntriesCompanion entry) async {
    await transaction(() async {
      final profile = await (profileEntries.select()..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
      if (profile == null) {
        loggy.log(LogLevel.info, 'profile with id : [$id] deleted');
        return;
      }
      if (entry.active.present && entry.active.value) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      await (update(profileEntries)..where((tbl) => tbl.id.equals(id))).write(entry);
    });
  }

  @override
  Future<void> deleteById(String id, bool isActive) async {
    await transaction(() async {
      await (delete(profileEntries)..where((tbl) => tbl.id.equals(id))).go();

      if (isActive) {
        final profiles = await (profileEntries.select()..where((tbl) => tbl.id.equals(id).not())).get();
        if (profiles.isEmpty) return;
        final prof = profiles.first;
        await (update(
          profileEntries,
        )..where((tbl) => tbl.id.equals(prof.id))).write(const ProfileEntriesCompanion(active: Value(true)));
      }
    });
  }
}
