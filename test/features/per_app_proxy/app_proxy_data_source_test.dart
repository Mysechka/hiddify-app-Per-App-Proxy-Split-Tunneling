import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/per_app_proxy/data/app_proxy_data_source.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_backup.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/per_app_proxy/model/pkg_flag.dart';

void main() {
  late Db db;
  late AppProxyDao dao;

  setUp(() {
    db = Db(NativeDatabase.memory());
    dao = AppProxyDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('AppProxyDao CRUD & Toggle', () {
    test('updatePkg inserts user selection when entry does not exist', () async {
      await dao.updatePkg(pkg: 'com.example.app', mode: AppProxyMode.include);

      final entries = await dao.watchAll(mode: AppProxyMode.include).first;
      expect(entries.length, 1);
      expect(entries.first.pkgName, 'com.example.app');
      expect(PkgFlag.userSelection.check(entries.first.flags), isTrue);
    });

    test('updatePkg removes entry when user toggles off a non-auto-selected app', () async {
      await dao.updatePkg(pkg: 'com.example.app', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'com.example.app', mode: AppProxyMode.include);

      final entries = await dao.watchAll(mode: AppProxyMode.include).first;
      expect(entries, isEmpty);
    });

    test('updatePkg handles auto-selected items with force deselection cycle', () async {
      // Apply auto selection first
      await dao.applyAutoSelection(
        autoList: {'com.example.auto'},
        mode: AppProxyMode.exclude,
      );

      var entries = await dao.watchAll(mode: AppProxyMode.exclude).first;
      expect(entries.length, 1);
      expect(PkgFlag.autoSelection.check(entries.first.flags), isTrue);
      expect(PkgFlag.forceDeselection.check(entries.first.flags), isFalse);

      // 1st update on auto-selected item -> adds userSelection
      await dao.updatePkg(pkg: 'com.example.auto', mode: AppProxyMode.exclude);
      entries = await dao.watchAll(mode: AppProxyMode.exclude).first;
      expect(PkgFlag.userSelection.check(entries.first.flags), isTrue);

      // 2nd update -> adds forceDeselection
      await dao.updatePkg(pkg: 'com.example.auto', mode: AppProxyMode.exclude);
      entries = await dao.watchAll(mode: AppProxyMode.exclude).first;
      expect(PkgFlag.forceDeselection.check(entries.first.flags), isTrue);

      // 3rd update -> removes forceDeselection and userSelection
      await dao.updatePkg(pkg: 'com.example.auto', mode: AppProxyMode.exclude);
      entries = await dao.watchAll(mode: AppProxyMode.exclude).first;
      expect(PkgFlag.forceDeselection.check(entries.first.flags), isFalse);
      expect(PkgFlag.userSelection.check(entries.first.flags), isFalse);
      expect(PkgFlag.autoSelection.check(entries.first.flags), isTrue);
    });
  });

  group('AppProxyDao Queries & Streams', () {
    test('watchFilterForDisplay returns only matching phone packages', () async {
      await dao.updatePkg(pkg: 'app1', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'app2', mode: AppProxyMode.include);

      final stream1 = dao.watchFilterForDisplay(
        phonePkgs: {'app1'},
        mode: AppProxyMode.include,
      );
      final result1 = await stream1.first;
      expect(result1.length, 1);
      expect(result1.first.pkgName, 'app1');

      final streamEmpty = dao.watchFilterForDisplay(
        phonePkgs: {},
        mode: AppProxyMode.include,
      );
      expect(await streamEmpty.first, isEmpty);
    });

    test('watchActivePackages excludes force-deselected packages', () async {
      await dao.applyAutoSelection(
        autoList: {'app1', 'app2'},
        mode: AppProxyMode.include,
      );
      // User selection on app1 -> force deselection cycle
      await dao.updatePkg(pkg: 'app1', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'app1', mode: AppProxyMode.include);

      final active = await dao.watchActivePackages(
        phonePkgs: {'app1', 'app2'},
        mode: AppProxyMode.include,
      ).first;

      expect(active.contains('app2'), isTrue);
      expect(active.contains('app1'), isFalse);
    });

    test('getPkgsByFlag returns list of package names matching specific flag', () async {
      await dao.updatePkg(pkg: 'app1', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'app2', mode: AppProxyMode.include);

      final pkgs = await dao.getPkgsByFlag(
        flag: PkgFlag.userSelection,
        mode: AppProxyMode.include,
      );
      expect(pkgs, containsAll(['app1', 'app2']));
    });
  });

  group('AppProxyDao Backup, AutoSelection & Clear', () {
    test('importPkgs restores selected and deselected packages correctly', () async {
      const backup = PerAppProxyBackup(
        include: PerAppProxyBackupMode(
          selected: ['inc.app1', 'inc.app2'],
          deselected: ['inc.app3'],
        ),
        exclude: PerAppProxyBackupMode(
          selected: ['exc.app1'],
        ),
      );

      await dao.importPkgs(backup: backup);

      final incSelected = await dao.getPkgsByFlag(
        flag: PkgFlag.userSelection,
        mode: AppProxyMode.include,
      );
      expect(incSelected, containsAll(['inc.app1', 'inc.app2']));

      final incDeselected = await dao.getPkgsByFlag(
        flag: PkgFlag.forceDeselection,
        mode: AppProxyMode.include,
      );
      expect(incDeselected, contains('inc.app3'));

      final excSelected = await dao.getPkgsByFlag(
        flag: PkgFlag.userSelection,
        mode: AppProxyMode.exclude,
      );
      expect(excSelected, contains('exc.app1'));
    });

    test('revertForceDeselection removes force deselection flags', () async {
      await dao.applyAutoSelection(
        autoList: {'app1'},
        mode: AppProxyMode.include,
      );
      // Put app1 into force deselection
      await dao.updatePkg(pkg: 'app1', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'app1', mode: AppProxyMode.include);

      await dao.revertForceDeselection(mode: AppProxyMode.include);

      final deselected = await dao.getPkgsByFlag(
        flag: PkgFlag.forceDeselection,
        mode: AppProxyMode.include,
      );
      expect(deselected, isEmpty);
    });

    test('clearAutoSelected removes autoSelection and clears single-auto items', () async {
      await dao.applyAutoSelection(
        autoList: {'auto1'},
        mode: AppProxyMode.include,
      );
      await dao.updatePkg(pkg: 'manual1', mode: AppProxyMode.include);

      await dao.clearAutoSelected(mode: AppProxyMode.include);

      final entries = await dao.watchAll(mode: AppProxyMode.include).first;
      expect(entries.length, 1);
      expect(entries.first.pkgName, 'manual1');
    });

    test('clearAll clears only the specified mode', () async {
      await dao.updatePkg(pkg: 'inc1', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'exc1', mode: AppProxyMode.exclude);

      await dao.clearAll(mode: AppProxyMode.include);

      final incEntries = await dao.watchAll(mode: AppProxyMode.include).first;
      final excEntries = await dao.watchAll(mode: AppProxyMode.exclude).first;

      expect(incEntries, isEmpty);
      expect(excEntries.length, 1);
      expect(excEntries.first.pkgName, 'exc1');
    });
  });
}
