import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/db/provider/db_providers.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/per_app_proxy/data/app_proxy_data_source.dart';
import 'package:hiddify/features/per_app_proxy/data/selected_data_provider.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_backup.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/per_app_proxy/model/pkg_flag.dart';
import 'package:hiddify/features/per_app_proxy/overview/per_app_proxy_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Db db;
  late AppProxyDao dao;
  late ProviderContainer container;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = Db(NativeDatabase.memory());
    dao = AppProxyDao(db);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => prefs),
        dbProvider.overrideWithValue(db),
        appProxyDataSourceProvider.overrideWithValue(dao),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('PerAppProxy Notifier Provider', () {
    test('build returns empty stream when mode is null', () async {
      final stream = container.read(perAppProxyProvider(null).future);
      final result = await stream;
      expect(result, isEmpty);
    });

    test('updatePkg updates database and reflects in notifier stream', () async {
      final notifier = container.read(perAppProxyProvider(AppProxyMode.include).notifier);

      // Initially no items
      await dao.updatePkg(pkg: 'test.app', mode: AppProxyMode.include);

      final entries = await dao.watchAll(mode: AppProxyMode.include).first;
      expect(entries.length, 1);
      expect(entries.first.pkgName, 'test.app');

      // Update pkg via notifier
      await notifier.updatePkg('test.app');
      final entriesAfterToggle = await dao.watchAll(mode: AppProxyMode.include).first;
      expect(entriesAfterToggle, isEmpty);
    });

    test('clearAll removes all entries for current mode', () async {
      await dao.updatePkg(pkg: 'app1', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'app2', mode: AppProxyMode.include);

      final notifier = container.read(perAppProxyProvider(AppProxyMode.include).notifier);
      await notifier.clearAll();

      final entries = await dao.watchAll(mode: AppProxyMode.include).first;
      expect(entries, isEmpty);
    });

    test('revertForceDeselection removes force deselection flag for current mode', () async {
      await dao.applyAutoSelection(
        autoList: {'auto.app'},
        mode: AppProxyMode.include,
      );
      // Toggle to force deselection
      await dao.updatePkg(pkg: 'auto.app', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'auto.app', mode: AppProxyMode.include);

      final notifier = container.read(perAppProxyProvider(AppProxyMode.include).notifier);
      await notifier.revertForceDeselection();

      final deselected = await dao.getPkgsByFlag(
        flag: PkgFlag.forceDeselection,
        mode: AppProxyMode.include,
      );
      expect(deselected, isEmpty);
    });

    test('clearAutoSelected clears auto-selected apps in current mode', () async {
      await dao.applyAutoSelection(
        autoList: {'auto.app'},
        mode: AppProxyMode.include,
      );
      await dao.updatePkg(pkg: 'manual.app', mode: AppProxyMode.include);

      final notifier = container.read(perAppProxyProvider(AppProxyMode.include).notifier);
      await notifier.clearAutoSelected();

      final entries = await dao.watchAll(mode: AppProxyMode.include).first;
      expect(entries.length, 1);
      expect(entries.first.pkgName, 'manual.app');
    });

    test('JSON Backup import & export roundtrip', () async {
      const originalBackup = PerAppProxyBackup(
        include: PerAppProxyBackupMode(
          selected: ['com.app.one', 'com.app.two'],
          deselected: ['com.app.three'],
        ),
        exclude: PerAppProxyBackupMode(
          selected: ['com.app.four'],
        ),
      );

      // Import via DAO directly
      await dao.importPkgs(backup: originalBackup);

      // Verify imported values in DAO
      final incSelected = await dao.getPkgsByFlag(
        flag: PkgFlag.userSelection,
        mode: AppProxyMode.include,
      );
      final incDeselected = await dao.getPkgsByFlag(
        flag: PkgFlag.forceDeselection,
        mode: AppProxyMode.include,
      );
      final excSelected = await dao.getPkgsByFlag(
        flag: PkgFlag.userSelection,
        mode: AppProxyMode.exclude,
      );

      expect(incSelected, containsAll(['com.app.one', 'com.app.two']));
      expect(incDeselected, contains('com.app.three'));
      expect(excSelected, contains('com.app.four'));

      // Construct exported backup from DAO data
      final exportedBackup = PerAppProxyBackup(
        include: PerAppProxyBackupMode(
          selected: incSelected,
          deselected: incDeselected,
        ),
        exclude: PerAppProxyBackupMode(
          selected: excSelected,
          deselected: await dao.getPkgsByFlag(mode: AppProxyMode.exclude, flag: PkgFlag.forceDeselection),
        ),
      );

      final jsonStr = jsonEncode(exportedBackup.toJson());
      final redecoded = PerAppProxyBackup.fromJson((jsonDecode(jsonStr) as Map).cast());

      expect(redecoded.include.selected, containsAll(originalBackup.include.selected));
      expect(redecoded.include.deselected, containsAll(originalBackup.include.deselected));
      expect(redecoded.exclude.selected, containsAll(originalBackup.exclude.selected));
    });
  });
}
