import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/db/provider/db_providers.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/per_app_proxy/data/app_proxy_data_source.dart';
import 'package:hiddify/features/per_app_proxy/data/selected_data_provider.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_backup.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/per_app_proxy/model/pkg_flag.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
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

  group('Split Tunneling Integration E2E', () {
    test('Scenario 1: Enable Split Tunneling Exclude Mode -> Select Apps -> Verify sing-box routing rules', () async {
      // Step 1: Set mode to exclude (Bypass selected apps)
      await container.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.exclude);
      expect(container.read(Preferences.perAppProxyMode), equals(PerAppProxyMode.exclude));

      // Step 2: Add apps to exclude list
      final selectedApps = ['Telegram.exe', 'chrome.exe'];
      await container.read(Preferences.excludeApps.notifier).update(selectedApps);
      expect(container.read(Preferences.excludeApps), equals(selectedApps));

      // Step 3: Generate sing-box Rule for Exclude Mode
      final perAppExcludeRule = Rule(
        name: 'Per-App Exclude',
        outbound: Outbound.direct,
        processNames: container.read(Preferences.excludeApps),
        enabled: true,
      );

      final routeRule = RouteRule(rules: [perAppExcludeRule]);
      final jsonMap = routeRule.toProto3Json()! as Map<String, dynamic>;

      expect(jsonMap['rules'], isNotEmpty);
      final rules = jsonMap['rules'] as List;
      expect(rules.length, 1);

      final rule = rules.first as Map<String, dynamic>;
      expect(rule['name'], 'Per-App Exclude');
      expect(rule['outbound'], 'direct');
      expect(rule['process_name'], containsAll(['Telegram.exe', 'chrome.exe']));
    });

    test('Scenario 2: Switch to Include Mode (Proxy selected apps) -> Verify proxy rule + fallback direct rule', () async {
      // Step 1: Set mode to include (Only proxy selected apps)
      await container.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.include);
      expect(container.read(Preferences.perAppProxyMode), equals(PerAppProxyMode.include));

      // Step 2: Set included apps
      final includedApps = ['Spotify.exe', 'Discord.exe'];
      await container.read(Preferences.includeApps.notifier).update(includedApps);
      expect(container.read(Preferences.includeApps), equals(includedApps));

      // Step 3: Generate sing-box Rules for Include Mode
      final perAppIncludeRule = Rule(
        name: 'Per-App Include',
        outbound: Outbound.proxy,
        processNames: container.read(Preferences.includeApps),
        enabled: true,
      );
      final directRemainingRule = Rule(
        name: 'Per-App Direct Remaining',
        outbound: Outbound.direct,
        network: Network.all,
        enabled: true,
      );

      final routeRule = RouteRule(rules: [perAppIncludeRule, directRemainingRule]);
      final jsonMap = routeRule.toProto3Json()! as Map<String, dynamic>;

      final rules = jsonMap['rules'] as List;
      expect(rules.length, 2);

      // Verify Include rule is first
      final firstRule = rules[0] as Map<String, dynamic>;
      expect(firstRule['name'], 'Per-App Include');
      expect(firstRule['outbound'], 'proxy');
      expect(firstRule['process_name'], containsAll(['Spotify.exe', 'Discord.exe']));

      // Verify Fallback direct rule is second
      final secondRule = rules[1] as Map<String, dynamic>;
      expect(secondRule['name'], 'Per-App Direct Remaining');
      expect(secondRule['outbound'], 'direct');
    });

    test('Scenario 3: Backup configuration -> Mutate state -> Restore backup -> Verify exact recovery', () async {
      // Populate database with include and exclude configurations
      await dao.updatePkg(pkg: 'AppA', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'AppB', mode: AppProxyMode.include);
      await dao.updatePkg(pkg: 'AppC', mode: AppProxyMode.exclude);

      // Create backup
      final backup = PerAppProxyBackup(
        include: PerAppProxyBackupMode(
          selected: await dao.getPkgsByFlag(mode: AppProxyMode.include, flag: PkgFlag.userSelection),
          deselected: await dao.getPkgsByFlag(mode: AppProxyMode.include, flag: PkgFlag.forceDeselection),
        ),
        exclude: PerAppProxyBackupMode(
          selected: await dao.getPkgsByFlag(mode: AppProxyMode.exclude, flag: PkgFlag.userSelection),
          deselected: await dao.getPkgsByFlag(mode: AppProxyMode.exclude, flag: PkgFlag.forceDeselection),
        ),
      );

      final backupJson = jsonEncode(backup.toJson());

      // Mutate / Clear state
      await dao.clearAll(mode: AppProxyMode.include);
      await dao.clearAll(mode: AppProxyMode.exclude);
      expect(await dao.watchAll(mode: AppProxyMode.include).first, isEmpty);
      expect(await dao.watchAll(mode: AppProxyMode.exclude).first, isEmpty);

      // Restore backup
      final restoredBackup = PerAppProxyBackup.fromJson((jsonDecode(backupJson) as Map).cast());
      await dao.importPkgs(backup: restoredBackup);

      // Verify restored data
      final restoredInclude = await dao.getPkgsByFlag(mode: AppProxyMode.include, flag: PkgFlag.userSelection);
      final restoredExclude = await dao.getPkgsByFlag(mode: AppProxyMode.exclude, flag: PkgFlag.userSelection);

      expect(restoredInclude, containsAll(['AppA', 'AppB']));
      expect(restoredExclude, contains('AppC'));
    });
  });
}
