import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hiddify/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:hiddify/features/per_app_proxy/model/app_package_info.dart';
import 'package:path/path.dart' as p;

class DesktopInstalledAppsService {
  static List<AppPackageInfo>? _cachedApps;

  static void clearCache() {
    _cachedApps = null;
    WindowsInstalledAppsService.clearCache();
  }

  static Future<Set<AppPackageInfo>> getInstalledApps({
    bool hideSystem = false,
    bool forceRefresh = false,
  }) async {
    if (Platform.isWindows) {
      return await WindowsInstalledAppsService.getInstalledApps(
        hideSystem: hideSystem,
        forceRefresh: forceRefresh,
      );
    }

    if (!forceRefresh && _cachedApps != null) {
      return _cachedApps!
          .where((app) => !hideSystem || !app.isSystem)
          .toSet();
    }

    final List<AppPackageInfo> apps;
    if (Platform.isMacOS) {
      apps = await _scanMacOSApps();
    } else if (Platform.isLinux) {
      apps = await _scanLinuxApps();
    } else {
      apps = [];
    }

    // Deduplicate by packageName and sort by app name
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

  // --- macOS Implementation ---

  static Future<List<AppPackageInfo>> _scanMacOSApps() async {
    final home = Platform.environment['HOME'];
    final candidateDirs = <String>[
      '/Applications',
      '/System/Applications',
      '/System/Applications/Utilities',
      '/Applications/Utilities',
      if (home != null && home.isNotEmpty) p.join(home, 'Applications'),
    ];

    final appDirs = <String>{};

    for (final dirPath in candidateDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;

      try {
        final entries = dir.listSync(followLinks: false);
        for (final entry in entries) {
          if (entry is! Directory) continue;
          final name = p.basename(entry.path);
          if (name.startsWith('.')) continue;

          if (name.endsWith('.app')) {
            appDirs.add(entry.path);
          } else {
            // Check 1 level deeper for directories like Utilities
            try {
              final subEntries = entry.listSync(followLinks: false);
              for (final sub in subEntries) {
                if (sub is Directory && sub.path.endsWith('.app')) {
                  appDirs.add(sub.path);
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    final results = <AppPackageInfo>[];

    for (final appPath in appDirs) {
      try {
        File plistFile = File(p.join(appPath, 'Contents', 'Info.plist'));
        if (!plistFile.existsSync()) {
          final wrapped = File(p.join(appPath, 'Wrapper', 'Runner.app', 'Info.plist'));
          if (wrapped.existsSync()) {
            plistFile = wrapped;
          } else {
            final direct = File(p.join(appPath, 'Info.plist'));
            if (direct.existsSync()) {
              plistFile = direct;
            } else {
              continue;
            }
          }
        }

        final isSystem = appPath.startsWith('/System/');
        final folderBaseName = p.basename(appPath).replaceAll(RegExp(r'\.app$', caseSensitive: false), '');

        String plistContent = '';
        try {
          final headerBytes = await plistFile.openRead(0, 8).first;
          final isBinary = headerBytes.length >= 8 &&
              headerBytes[0] == 0x62 && // b
              headerBytes[1] == 0x70 && // p
              headerBytes[2] == 0x6C && // l
              headerBytes[3] == 0x69 && // i
              headerBytes[4] == 0x73 && // s
              headerBytes[5] == 0x74 && // t
              headerBytes[6] == 0x30 && // 0
              headerBytes[7] == 0x30;   // 0

          if (isBinary) {
            final processResult = Process.runSync('plutil', ['-convert', 'xml1', '-o', '-', plistFile.path]);
            if (processResult.exitCode == 0 && processResult.stdout is String) {
              plistContent = processResult.stdout as String;
            }
          } else {
            plistContent = await plistFile.readAsString();
          }
        } catch (_) {
          try {
            plistContent = await plistFile.readAsString(encoding: latin1);
          } catch (_) {}
        }

        String? getPlistString(String key) {
          final regExp = RegExp(
            '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>([^<]*)</string>',
            caseSensitive: false,
          );
          final match = regExp.firstMatch(plistContent);
          return match?.group(1)?.trim();
        }

        final displayName = getPlistString('CFBundleDisplayName');
        final bundleName = getPlistString('CFBundleName');
        final executable = getPlistString('CFBundleExecutable');
        final iconFile = getPlistString('CFBundleIconFile');

        final appName = (displayName != null && displayName.isNotEmpty)
            ? displayName
            : (bundleName != null && bundleName.isNotEmpty)
                ? bundleName
                : folderBaseName;

        final packageName = (executable != null && executable.isNotEmpty)
            ? executable
            : folderBaseName;

        // Icon extraction
        Uint8List? iconBytes;
        final resourcesDir = Directory(p.join(appPath, 'Contents', 'Resources'));
        if (resourcesDir.existsSync()) {
          iconBytes = await _findAndExtractMacOSIcon(resourcesDir, iconFile);
        } else {
          final searchDir = plistFile.parent;
          try {
            final files = searchDir.listSync(followLinks: false);
            for (final f in files) {
              if (f is File && f.path.toLowerCase().contains('icon') && f.path.endsWith('.png')) {
                iconBytes = await f.readAsBytes();
                break;
              }
            }
          } catch (_) {}
        }

        results.add(
          AppPackageInfo(
            packageName: packageName,
            name: appName,
            icon: iconBytes,
            isSystem: isSystem,
          ),
        );
      } catch (_) {}
    }

    return results;
  }

  static Future<Uint8List?> _findAndExtractMacOSIcon(
    Directory resourcesDir,
    String? iconFile,
  ) async {
    try {
      File? targetIconFile;

      if (iconFile != null && iconFile.isNotEmpty) {
        final direct = File(p.join(resourcesDir.path, iconFile));
        if (direct.existsSync()) {
          targetIconFile = direct;
        } else if (!iconFile.endsWith('.icns')) {
          final withExt = File(p.join(resourcesDir.path, '$iconFile.icns'));
          if (withExt.existsSync()) {
            targetIconFile = withExt;
          }
        }
      }

      if (targetIconFile == null) {
        final commonNames = ['AppIcon.icns', 'app.icns', 'icon.icns', 'electron.icns'];
        for (final name in commonNames) {
          final file = File(p.join(resourcesDir.path, name));
          if (file.existsSync()) {
            targetIconFile = file;
            break;
          }
        }
      }

      if (targetIconFile == null) {
        final entries = resourcesDir.listSync(followLinks: false);
        for (final entry in entries) {
          if (entry is File && entry.path.endsWith('.icns')) {
            targetIconFile = entry;
            break;
          }
        }
      }

      if (targetIconFile != null && targetIconFile.existsSync()) {
        final bytes = await targetIconFile.readAsBytes();
        return _extractPngFromIcns(bytes);
      }
    } catch (_) {}
    return null;
  }

  static Uint8List? _extractPngFromIcns(Uint8List data) {
    if (data.length < 8) return null;
    // Magic bytes 'icns' = 0x69, 0x63, 0x6E, 0x73
    if (data[0] != 0x69 || data[1] != 0x63 || data[2] != 0x6E || data[3] != 0x73) {
      return null;
    }

    var pos = 8;
    Uint8List? bestPng;

    while (pos + 8 <= data.length) {
      final tag = String.fromCharCodes(data.sublist(pos, pos + 4));
      final byteData = ByteData.sublistView(data, pos + 4, pos + 8);
      final length = byteData.getUint32(0);

      if (length < 8 || pos + length > data.length) break;

      final entry = data.sublist(pos + 8, pos + length);

      // PNG signature: 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
      if (entry.length >= 8 &&
          entry[0] == 0x89 &&
          entry[1] == 0x50 &&
          entry[2] == 0x4E &&
          entry[3] == 0x47 &&
          entry[4] == 0x0D &&
          entry[5] == 0x0A &&
          entry[6] == 0x1A &&
          entry[7] == 0x0A) {
        // Preferred icons for list tiles: ic07 (128x128), ic13 (256x256 / 128@2x), ic08 (256x256), ic12 (64x64)
        if (tag == 'ic07' || tag == 'ic13' || tag == 'ic08' || tag == 'ic12') {
          return entry;
        }
        if (bestPng == null || (entry.length > bestPng.length && entry.length < 250000)) {
          bestPng = entry;
        }
      }

      pos += length;
    }

    return bestPng;
  }

  // --- Linux Implementation ---

  static Future<List<AppPackageInfo>> _scanLinuxApps() async {
    final results = <AppPackageInfo>[];
    final home = Platform.environment['HOME'];
    final candidateDirs = <String>[
      '/usr/share/applications',
      '/usr/local/share/applications',
      if (home != null && home.isNotEmpty) p.join(home, '.local', 'share', 'applications'),
    ];

    for (final dirPath in candidateDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;

      try {
        final entries = dir.listSync(followLinks: false);
        for (final entry in entries) {
          if (entry is! File || !entry.path.endsWith('.desktop')) continue;
          try {
            final content = await entry.readAsString();
            final lines = content.split('\n');

            String? name;
            String? exec;
            bool noDisplay = false;

            for (final line in lines) {
              final trimmed = line.trim();
              if (trimmed.startsWith('Name=') && name == null) {
                name = trimmed.substring(5).trim();
              } else if (trimmed.startsWith('Exec=') && exec == null) {
                exec = trimmed.substring(5).trim().split(' ').first;
                exec = p.basename(exec);
              } else if (trimmed.startsWith('NoDisplay=true')) {
                noDisplay = true;
              }
            }

            if (noDisplay || name == null || exec == null || name.isEmpty || exec.isEmpty) {
              continue;
            }

            results.add(
              AppPackageInfo(
                packageName: exec,
                name: name,
                icon: null,
                isSystem: dirPath.startsWith('/usr'),
              ),
            );
          } catch (_) {}
        }
      } catch (_) {}
    }

    return results;
  }
}
