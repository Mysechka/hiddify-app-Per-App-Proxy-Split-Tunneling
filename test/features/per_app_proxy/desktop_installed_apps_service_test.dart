import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/per_app_proxy/data/desktop_installed_apps_service.dart';
import 'package:hiddify/features/per_app_proxy/model/app_package_info.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

void main() {
  group('AppPackageInfo', () {
    test('equality and hashcode are based on packageName', () {
      const app1 = AppPackageInfo(
        packageName: 'Telegram',
        name: 'Telegram Desktop',
        icon: null,
      );
      const app2 = AppPackageInfo(
        packageName: 'Telegram',
        name: 'Telegram',
        icon: null,
      );
      const app3 = AppPackageInfo(
        packageName: 'Google Chrome',
        name: 'Google Chrome',
        icon: null,
      );

      expect(app1, equals(app2));
      expect(app1.hashCode, equals(app2.hashCode));
      expect(app1, isNot(equals(app3)));

      final set = {app1, app2, app3};
      expect(set.length, 2);
    });
  });

  group('DesktopInstalledAppsService', () {
    test('scans macOS apps and extracts properties', () async {
      if (!Platform.isMacOS) return;

      final apps = await DesktopInstalledAppsService.getInstalledApps(hideSystem: false);
      expect(apps, isNotEmpty);

      // Check that packages have valid names and packageNames
      for (final app in apps) {
        expect(app.name, isNotEmpty);
        expect(app.packageName, isNotEmpty);
      }

      // Check system filtering
      final userApps = await DesktopInstalledAppsService.getInstalledApps(hideSystem: true);
      expect(userApps, isNotEmpty);
      expect(userApps.every((a) => !a.isSystem), isTrue);

      // Verify at least some apps have extracted icons
      final withIcons = apps.where((a) => a.icon != null && a.icon!.isNotEmpty);
      expect(withIcons, isNotEmpty);
    });
  });

  group('Sing-box Route Rules for Desktop Split Tunneling', () {
    test('Exclude rule serialization with process_name', () {
      final excludeRule = Rule(
        name: 'Per-App Exclude',
        outbound: Outbound.direct,
        processNames: ['Telegram', 'Google Chrome'],
        enabled: true,
      );

      final routeRule = RouteRule(rules: [excludeRule]);
      final jsonMap = routeRule.toProto3Json() as Map<String, dynamic>;

      expect(jsonMap['rules'], isNotNull);
      final rulesList = jsonMap['rules'] as List;
      expect(rulesList.length, 1);

      final ruleJson = rulesList[0] as Map<String, dynamic>;
      expect(ruleJson['name'], 'Per-App Exclude');
      expect(ruleJson['outbound'], 'direct');
      expect(ruleJson['process_name'], ['Telegram', 'Google Chrome']);
    });

    test('Include rules serialization with proxy and fallback direct', () {
      final includeRule = Rule(
        name: 'Per-App Include',
        outbound: Outbound.proxy,
        processNames: ['Telegram'],
        enabled: true,
      );
      final directRemainingRule = Rule(
        name: 'Per-App Direct Remaining',
        outbound: Outbound.direct,
        network: Network.all,
        enabled: true,
      );

      final routeRule = RouteRule(rules: [includeRule, directRemainingRule]);
      final jsonMap = routeRule.toProto3Json() as Map<String, dynamic>;

      final rulesList = jsonMap['rules'] as List;
      expect(rulesList.length, 2);

      final firstRule = rulesList[0] as Map<String, dynamic>;
      expect(firstRule['name'], 'Per-App Include');
      expect(firstRule['outbound'], 'proxy');
      expect(firstRule['process_name'], ['Telegram']);

      final secondRule = rulesList[1] as Map<String, dynamic>;
      expect(secondRule['name'], 'Per-App Direct Remaining');
      expect(secondRule['outbound'], 'direct');
    });
  });

  group('Icon validity & caching', () {
    test('Extracted macOS icons have valid PNG header', () async {
      if (!Platform.isMacOS) return;

      final apps = await DesktopInstalledAppsService.getInstalledApps(hideSystem: false);
      final appsWithIcon = apps.where((a) => a.icon != null && a.icon!.isNotEmpty).toList();
      expect(appsWithIcon, isNotEmpty);

      const pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      for (final app in appsWithIcon) {
        final iconBytes = app.icon!;
        expect(
          iconBytes.sublist(0, 8),
          equals(pngMagic),
          reason: 'App ${app.name} icon must have valid PNG signature',
        );
      }
    });

    test('DesktopInstalledAppsService caching returns identical results instantly', () async {
      final t1 = DateTime.now();
      final apps1 = await DesktopInstalledAppsService.getInstalledApps();
      final elapsed1 = DateTime.now().difference(t1);

      final t2 = DateTime.now();
      final apps2 = await DesktopInstalledAppsService.getInstalledApps();
      final elapsed2 = DateTime.now().difference(t2);

      expect(apps1.length, equals(apps2.length));
      expect(elapsed2.inMilliseconds, lessThan(10));
    });
  });
}
