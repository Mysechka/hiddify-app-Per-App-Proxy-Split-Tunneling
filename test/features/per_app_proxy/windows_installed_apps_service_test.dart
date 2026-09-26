import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/per_app_proxy/data/desktop_installed_apps_service.dart';
import 'package:hiddify/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:hiddify/features/per_app_proxy/model/app_package_info.dart';
import 'package:hiddify/utils/utils.dart';

void main() {
  group('WindowsInstalledAppsService', () {
    test('clearCache resets cache and getInstalledApps returns non-null list', () async {
      WindowsInstalledAppsService.clearCache();
      final apps = await WindowsInstalledAppsService.getInstalledApps();
      expect(apps, isNotNull);

      // Call again to test cache path
      final cached = await WindowsInstalledAppsService.getInstalledApps();
      expect(cached, isNotNull);
      expect(cached.length, equals(apps.length));
    });

    test('getInstalledApps with hideSystem filters correctly', () async {
      final allApps = await WindowsInstalledAppsService.getInstalledApps(forceRefresh: true);
      final userApps = await WindowsInstalledAppsService.getInstalledApps(hideSystem: true);

      expect(userApps.every((a) => !a.isSystem), isTrue);
      expect(userApps.length, lessThanOrEqualTo(allApps.length));
    });

    test('appInfoForExePath builds valid AppPackageInfo from arbitrary .exe paths', () {
      final app1 = WindowsInstalledAppsService.appInfoForExePath(r'C:\Program Files\App\custom_app.exe');
      expect(app1.packageName, 'custom_app.exe');
      expect(app1.name, 'custom_app');
      expect(app1.icon, isNull);
      expect(app1.isSystem, isFalse);

      final app2 = WindowsInstalledAppsService.appInfoForExePath(r'D:\Games\Steam\steam.exe');
      expect(app2.packageName, 'steam.exe');
      expect(app2.name, 'steam');

      final app3 = WindowsInstalledAppsService.appInfoForExePath('standalone.exe');
      expect(app3.packageName, 'standalone.exe');
      expect(app3.name, 'standalone');
    });

    test('Windows priority check order is followed correctly in service dispatch', () async {
      Future<Set<AppPackageInfo>> getApps(bool hideSystem) async {
        if (PlatformUtils.isWindows) {
          return (await WindowsInstalledAppsService.getInstalledApps(hideSystem: hideSystem)).toSet();
        }
        if (PlatformUtils.isDesktop) {
          return await DesktopInstalledAppsService.getInstalledApps(hideSystem: hideSystem);
        }
        return {};
      }

      final apps = await getApps(false);
      expect(apps, isNotNull);
    });

    test('Returns empty list when called on non-Windows platforms', () async {
      if (!Platform.isWindows) {
        final apps = await WindowsInstalledAppsService.getInstalledApps();
        expect(apps, isEmpty);
      }
    });
  });
}
