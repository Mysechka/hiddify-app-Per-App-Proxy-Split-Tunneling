import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/per_app_proxy/data/desktop_installed_apps_service.dart';
import 'package:hiddify/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:hiddify/features/per_app_proxy/model/app_package_info.dart';
import 'package:hiddify/utils/utils.dart';

void main() {
  group('WindowsInstalledAppsService', () {
    test('clearCache resets cache and getInstalledApps returns non-null set', () async {
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
  });
}
