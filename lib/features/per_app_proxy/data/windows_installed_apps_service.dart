import 'dart:io';

import 'package:hiddify/features/per_app_proxy/model/app_package_info.dart';
import 'package:path/path.dart' as p;

class WindowsInstalledAppsService {
  static List<AppPackageInfo>? _cachedApps;

  static void clearCache() {
    _cachedApps = null;
  }

  static Future<Set<AppPackageInfo>> getInstalledApps({
    bool hideSystem = false,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedApps != null) {
      return _cachedApps!
          .where((app) => !hideSystem || !app.isSystem)
          .toSet();
    }

    final List<AppPackageInfo> apps = await _scanWindowsApps();

    // Deduplicate by packageName (case-insensitive) and sort by app name
    final seen = <String>{};
    final uniqueApps = <AppPackageInfo>[];
    for (final app in apps) {
      if (seen.add(app.packageName.toLowerCase())) {
        uniqueApps.add(app);
      }
    }

    uniqueApps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _cachedApps = uniqueApps;

    return uniqueApps
        .where((app) => !hideSystem || !app.isSystem)
        .toSet();
  }

  static Future<List<AppPackageInfo>> _scanWindowsApps() async {
    final results = <AppPackageInfo>[];
    final appData = Platform.environment['APPDATA'];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final programData = Platform.environment['ProgramData'] ?? r'C:\ProgramData';

    final candidateDirs = <String>[
      if (appData != null && appData.isNotEmpty)
        p.join(appData, r'Microsoft\Windows\Start Menu\Programs'),
      p.join(programData, r'Microsoft\Windows\Start Menu\Programs'),
      if (localAppData != null && localAppData.isNotEmpty)
        p.join(localAppData, 'Programs'),
    ];

    for (final dirPath in candidateDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;

      try {
        final entries = dir.listSync(recursive: true, followLinks: false);
        for (final entry in entries) {
          if (entry is! File) continue;
          final ext = p.extension(entry.path).toLowerCase();
          if (ext != '.lnk' && ext != '.exe') continue;

          final baseName = p.basenameWithoutExtension(entry.path);
          final lowerBase = baseName.toLowerCase();
          if (lowerBase.startsWith('uninstall') ||
              lowerBase.startsWith('unins000') ||
              lowerBase.contains('help') ||
              lowerBase.contains('documentation') ||
              lowerBase.contains('readme') ||
              lowerBase.contains('license')) {
            continue;
          }

          final exeName = ext == '.exe' ? p.basename(entry.path) : '$baseName.exe';
          final isSystem = _isSystemApp(entry.path, baseName);

          results.add(
            AppPackageInfo(
              packageName: exeName,
              name: baseName,
              icon: null,
              isSystem: isSystem,
            ),
          );
        }
      } catch (_) {}
    }

    return results;
  }

  static bool _isSystemApp(String filePath, String baseName) {
    final lowerPath = filePath.toLowerCase();
    final lowerName = baseName.toLowerCase();
    return lowerPath.contains('windows powershell') ||
        lowerPath.contains('system32') ||
        lowerPath.contains('windows administrative tools') ||
        lowerPath.contains('windows accessories') ||
        lowerName == 'cmd' ||
        lowerName == 'powershell' ||
        lowerName == 'taskmgr';
  }
}
