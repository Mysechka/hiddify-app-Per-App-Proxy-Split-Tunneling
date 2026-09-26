import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hiddify/features/per_app_proxy/model/app_package_info.dart';
import 'package:path/path.dart' as p;

/// Discovers installed Windows applications for Per-App Proxy
/// (split tunneling by process name, supported in TUN mode via Wintun).
///
/// Data sources:
/// * Windows Registry Uninstall keys (`HKLM\...\Uninstall`,
///   `HKLM\...\Wow6432Node\...\Uninstall`, `HKCU\...\Uninstall`) queried with
///   a single PowerShell call ([DisplayName], [DisplayIcon],
///   [InstallLocation]).
/// * Start Menu shortcuts (`%ProgramData%` and `%AppData%`) with pure-Dart
///   `.lnk` target resolution.
/// * Optionally UWP / Microsoft Store packages via `Get-AppxPackage`
///   (framework and resource packages are filtered out).
///
/// The heavy scan runs in a background isolate via [compute] so the UI
/// thread never freezes. Icon extraction is best-effort: readable PNG/JPG
/// files and PNG-compressed entries of `.ico` files are returned as bytes,
/// anything else (e.g. icons embedded in `.exe`/`.dll`, which would require
/// Win32 GDI calls such as `ExtractIconExW` plus PNG encoding) yields `null`
/// and the UI shows a default icon.
class WindowsInstalledAppsService {
  const WindowsInstalledAppsService._();

  static List<AppPackageInfo>? _cachedApps;

  static void clearCache() {
    _cachedApps = null;
  }

  /// Returns installed Windows apps sorted by display name.
  ///
  /// [packageName] is the executable file name (e.g. `chrome.exe`) because
  /// sing-box matches desktop processes by `process_name` (matched
  /// case-insensitively on Windows, but an exact `*.exe` name is expected).
  static Future<List<AppPackageInfo>> getInstalledApps({
    bool hideSystem = false,
    bool forceRefresh = false,
  }) async {
    if (!Platform.isWindows) return [];

    if (!forceRefresh && _cachedApps != null) {
      return _cachedApps!
          .where((app) => !hideSystem || !app.isSystem)
          .toList();
    }

    final raw = await compute(_scanWindowsApps, false);
    final apps = <AppPackageInfo>[];
    final seen = <String>{};

    for (final entry in raw) {
      final packageName = entry['packageName'] as String?;
      final name = entry['name'] as String?;
      if (packageName == null || packageName.isEmpty) continue;
      if (name == null || name.isEmpty) continue;

      if (seen.add(packageName.toLowerCase())) {
        apps.add(
          AppPackageInfo(
            packageName: packageName,
            name: name,
            icon: entry['icon'] as Uint8List?,
            isSystem: entry['isSystem'] as bool? ?? false,
          ),
        );
      }
    }

    apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _cachedApps = apps;

    return apps
        .where((app) => !hideSystem || !app.isSystem)
        .toList();
  }

  /// Builds an [AppPackageInfo] for an `.exe` file picked manually via
  /// `FilePicker` (portable or rare apps missing from the registry and the
  /// Start Menu).
  static AppPackageInfo appInfoForExePath(String exePath) {
    final fileName = p.windows.basename(exePath);
    final name = p.windows.basenameWithoutExtension(exePath);
    return AppPackageInfo(
      packageName: fileName,
      name: name.isEmpty ? fileName : name,
      icon: null,
    );
  }
}

/// Internal scan record. Carries the resolved executable path so icons can
/// be loaded before the result is flattened into transferable maps.
class _WinApp {
  _WinApp({
    required this.name,
    required this.exeName,
    this.exePath,
    this.iconSource,
    this.isSystem = false,
  });

  final String name;
  final String exeName;
  final String? exePath;
  final String? iconSource;
  final bool isSystem;
}

/// Isolate entry point. Returns transferable maps (no custom objects) with
/// keys `packageName`, `name`, `icon` (`Uint8List` or `null`), `isSystem`.
List<Map<String, Object?>> _scanWindowsApps(bool hideSystem) {
  final merged = <String, Map<String, Object?>>{};

  void add(_WinApp app) {
    final packageName = app.exeName.trim();
    if (packageName.isEmpty || !packageName.toLowerCase().endsWith('.exe')) {
      return;
    }
    final name = app.name.trim().isEmpty ? packageName : app.name.trim();
    merged.putIfAbsent(
      packageName.toLowerCase(),
      () => <String, Object?>{
        'packageName': packageName,
        'name': name,
        'icon': _loadIconBytes(app.iconSource ?? app.exePath ?? ''),
        'isSystem': app.isSystem,
      },
    );
  }

  for (final app in _readRegistryApps()) {
    add(app);
  }
  for (final app in _readStartMenuApps()) {
    add(app);
  }
  for (final app in _readUwpApps()) {
    add(app);
  }

  final list = merged.values
      .where((entry) => !hideSystem || entry['isSystem'] != true)
      .toList()
    ..sort(
      (a, b) => (a['name']! as String)
          .toLowerCase()
          .compareTo((b['name']! as String).toLowerCase()),
    );
  return list;
}

// --- Registry (Uninstall keys) ---

List<_WinApp> _readRegistryApps() {
  const script = r'''
$ErrorActionPreference = 'SilentlyContinue';
$paths = @(
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
);
Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -ne $null -and "$($_.DisplayName)".Trim() -ne '' } |
  Select-Object DisplayName, DisplayIcon, InstallLocation, Publisher, SystemComponent |
  ConvertTo-Json -Compress -Depth 2
''';
  try {
    final result = Process.runSync(
      'powershell',
      const [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
    );
    if (result.exitCode != 0) return [];
    final stdout = (result.stdout as String).trim();
    if (stdout.isEmpty) return [];
    final decoded = jsonDecode(stdout);
    final entries = decoded is List ? decoded : <Object?>[decoded];
    final apps = <_WinApp>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final displayName = (entry['DisplayName']?.toString() ?? '').trim();
      if (displayName.isEmpty) continue;
      // Windows update packages, not routable applications.
      if (RegExp(r'^KB\d+', caseSensitive: false).hasMatch(displayName)) {
        continue;
      }
      final displayIcon = entry['DisplayIcon']?.toString() ?? '';
      final installLocation = entry['InstallLocation']?.toString() ?? '';
      final systemComponent = entry['SystemComponent'];
      final isSystem =
          (systemComponent is int && systemComponent != 0) ||
              (systemComponent is String &&
                  systemComponent.isNotEmpty &&
                  systemComponent != '0') ||
              _isWindowsPath(installLocation);
      String? exePath = _exeFromIconRef(displayIcon);
      exePath ??= _guessExeInDir(installLocation, displayName);
      // Without a real process name the entry is useless for sing-box
      // `process_name` routing, so it is skipped.
      if (exePath == null) continue;
      apps.add(
        _WinApp(
          name: displayName,
          exeName: p.basename(exePath),
          exePath: exePath,
          iconSource: displayIcon.isNotEmpty ? displayIcon : exePath,
          isSystem: isSystem,
        ),
      );
    }
    return apps;
  } catch (_) {
    return [];
  }
}

/// Resolves `DisplayIcon` values such as `"C:\...\app.exe",0` to an existing
/// `.exe` path, or `null` when it does not reference an executable.
String? _exeFromIconRef(String ref) {
  var value = _stripQuotes(ref.trim());
  if (value.isEmpty) return null;
  final commaIndex = value.lastIndexOf(',');
  if (commaIndex > 0 &&
      RegExp(r'^,\d+$').hasMatch(value.substring(commaIndex))) {
    value = _stripQuotes(value.substring(0, commaIndex).trim());
  }
  value = _expandEnv(value);
  if (!value.toLowerCase().endsWith('.exe')) return null;
  try {
    return File(value).existsSync() ? value : null;
  } catch (_) {
    return null;
  }
}

/// Picks the most likely main executable inside [dir]: a single `.exe`
/// wins, otherwise an executable matching [displayName] tokens, otherwise
/// the largest `.exe` (main binaries are usually bigger than uninstallers).
String? _guessExeInDir(String dir, String displayName) {
  if (dir.trim().isEmpty) return null;
  final expanded = _expandEnv(_stripQuotes(dir.trim()));
  final directory = Directory(expanded);
  bool exists = false;
  try {
    exists = directory.existsSync();
  } catch (_) {
    return null;
  }
  if (!exists) return null;
  List<FileSystemEntity> entries;
  try {
    entries = directory.listSync(followLinks: false);
  } catch (_) {
    return null;
  }
  final exes = <File>[];
  for (final entry in entries) {
    if (entry is! File) continue;
    if (!entry.path.toLowerCase().endsWith('.exe')) continue;
    final base = p.basename(entry.path).toLowerCase();
    if (base.startsWith('uninstall') || base.startsWith('unins')) continue;
    exes.add(entry);
    if (exes.length >= 50) break;
  }
  if (exes.isEmpty) return null;
  if (exes.length == 1) return exes.single.path;
  for (final token in _nameTokens(displayName)) {
    for (final exe in exes) {
      if (p.basename(exe.path).toLowerCase().contains(token)) {
        return exe.path;
      }
    }
  }
  File best = exes.first;
  int bestSize = -1;
  for (final exe in exes) {
    try {
      final size = exe.lengthSync();
      if (size > bestSize) {
        bestSize = size;
        best = exe;
      }
    } catch (_) {}
  }
  return best.path;
}

List<String> _nameTokens(String displayName) {
  return displayName
      .toLowerCase()
      .split(RegExp('[^a-z0-9]+'))
      .where((token) => token.length >= 3)
      .take(4)
      .toList();
}

// --- Start Menu shortcuts ---

List<_WinApp> _readStartMenuApps() {
  final apps = <_WinApp>[];
  final roots = <String>[];
  final appData = Platform.environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    roots.add(
      p.join(appData, 'Microsoft', 'Windows', 'Start Menu', 'Programs'),
    );
  }
  final programData = Platform.environment['ProgramData'];
  roots.add(
    p.join(
      programData ?? r'C:\ProgramData',
      'Microsoft',
      'Windows',
      'Start Menu',
      'Programs',
    ),
  );
  var scannedFiles = 0;
  for (final root in roots) {
    final dir = Directory(root);
    bool exists = false;
    try {
      exists = dir.existsSync();
    } catch (_) {
      continue;
    }
    if (!exists) continue;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(recursive: true, followLinks: false);
    } catch (_) {
      continue;
    }
    for (final entry in entries) {
      if (entry is! File) continue;
      if (++scannedFiles > 5000) break;
      final ext = p.extension(entry.path).toLowerCase();
      if (ext == '.url' || ext == '.ini') continue;
      final baseName = p.basenameWithoutExtension(entry.path);
      if (_isHelperShortcut(baseName)) continue;
      if (ext == '.exe') {
        apps.add(
          _WinApp(
            name: baseName,
            exeName: p.basename(entry.path),
            exePath: entry.path,
            isSystem: _isWindowsPath(entry.path),
          ),
        );
        continue;
      }
      if (ext != '.lnk') continue;
      final target = _resolveLnkTarget(entry);
      if (target == null || !target.toLowerCase().endsWith('.exe')) continue;
      final exeName = p.basename(target);
      if (exeName.isEmpty) continue;
      apps.add(
        _WinApp(
          name: baseName,
          exeName: exeName,
          exePath: target,
          isSystem: _isWindowsPath(target),
        ),
      );
    }
  }
  return apps;
}

bool _isHelperShortcut(String baseName) {
  final lower = baseName.toLowerCase();
  return lower.startsWith('uninstall') ||
      lower.startsWith('unins') ||
      lower.startsWith('readme') ||
      lower.contains('help');
}

/// Resolves the target path of a `.lnk` file: structured `LinkInfo` parsing
/// first (MS-SHLLINK), regex scan of embedded paths as fallback.
String? _resolveLnkTarget(File file) {
  Uint8List bytes;
  try {
    final size = file.lengthSync();
    if (size <= 0 || size > 4 * 1024 * 1024) return null;
    bytes = file.readAsBytesSync();
  } catch (_) {
    return null;
  }
  final structured = _parseLnkLinkInfo(bytes);
  if (structured != null && structured.toLowerCase().endsWith('.exe')) {
    return _expandEnv(structured);
  }
  return _findExeInBytes(bytes);
}

String? _parseLnkLinkInfo(Uint8List bytes) {
  try {
    if (bytes.length < 76) return null;
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(0, Endian.little) != 76) return null;
    final flags = view.getUint32(20, Endian.little);
    const hasLinkTargetIdList = 0x01;
    const hasLinkInfo = 0x02;
    const isUnicode = 0x80;
    var pos = 76;
    if ((flags & hasLinkTargetIdList) != 0) {
      if (pos + 2 > bytes.length) return null;
      final idListSize = view.getUint16(pos, Endian.little);
      pos += 2 + idListSize;
      if (pos < 0 || pos > bytes.length) return null;
    }
    final candidates = <String>[];
    var stringDataPos = pos;
    if ((flags & hasLinkInfo) != 0) {
      final infoStart = pos;
      if (infoStart + 28 > bytes.length) return null;
      final infoSize = view.getUint32(infoStart, Endian.little);
      final headerSize = view.getUint32(infoStart + 4, Endian.little);
      final localBaseOffset = view.getUint32(infoStart + 16, Endian.little);
      final suffixOffset = view.getUint32(infoStart + 24, Endian.little);
      int localBaseOffsetUnicode = 0;
      int suffixOffsetUnicode = 0;
      if (headerSize >= 0x24 && infoStart + 44 <= bytes.length) {
        localBaseOffsetUnicode = view.getUint32(infoStart + 28, Endian.little);
        suffixOffsetUnicode = view.getUint32(infoStart + 32, Endian.little);
      }
      if (infoSize <= 0 || infoStart + infoSize > bytes.length) return null;
      String readAt(int offset, bool unicode) => unicode
          ? _readUtf16String(bytes, infoStart + offset)
          : _readAnsiString(bytes, infoStart + offset);
      var localBase = '';
      var suffix = '';
      if (localBaseOffsetUnicode != 0) {
        localBase = readAt(localBaseOffsetUnicode, true);
      } else if (localBaseOffset != 0) {
        localBase = readAt(localBaseOffset, false);
      }
      if (suffixOffsetUnicode != 0) {
        suffix = readAt(suffixOffsetUnicode, true);
      } else if (suffixOffset != 0) {
        suffix = readAt(suffixOffset, false);
      }
      final combined = (localBase + suffix).trim();
      if (combined.isNotEmpty) candidates.add(combined);
      stringDataPos = infoStart + infoSize;
    }
    // StringData: optional strings in fixed order (name, relative path,
    // working dir, arguments, icon location).
    const stringFlags = [0x04, 0x08, 0x10, 0x20, 0x40];
    const relativePathFlag = 0x08;
    final unicodeStrings = (flags & isUnicode) != 0;
    var cursor = stringDataPos;
    for (final bit in stringFlags) {
      if ((flags & bit) == 0) continue;
      if (cursor + 2 > bytes.length) break;
      final count = view.getUint16(cursor, Endian.little);
      cursor += 2;
      final byteCount = count * (unicodeStrings ? 2 : 1);
      if (byteCount < 0 || cursor + byteCount > bytes.length) break;
      String value;
      if (unicodeStrings) {
        final units = <int>[];
        for (var i = 0; i < count; i++) {
          units.add(view.getUint16(cursor + i * 2, Endian.little));
        }
        value = String.fromCharCodes(units);
      } else {
        value = latin1.decode(bytes.sublist(cursor, cursor + byteCount));
      }
      cursor += byteCount;
      if (bit == relativePathFlag && value.trim().isNotEmpty) {
        candidates.add(value.trim());
      }
    }
    for (final candidate in candidates) {
      if (candidate.toLowerCase().endsWith('.exe')) return candidate;
    }
    return null;
  } catch (_) {
    return null;
  }
}

String _readAnsiString(Uint8List bytes, int absOffset) {
  if (absOffset < 0 || absOffset >= bytes.length) return '';
  var end = absOffset;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  try {
    return latin1.decode(bytes.sublist(absOffset, end));
  } catch (_) {
    return '';
  }
}

String _readUtf16String(Uint8List bytes, int absOffset) {
  if (absOffset < 0 || absOffset + 1 >= bytes.length) return '';
  final units = <int>[];
  var pos = absOffset;
  while (pos + 1 < bytes.length) {
    final unit = bytes[pos] | (bytes[pos + 1] << 8);
    if (unit == 0) break;
    units.add(unit);
    pos += 2;
    if (units.length > 1024) break;
  }
  try {
    return String.fromCharCodes(units);
  } catch (_) {
    return '';
  }
}

String? _findExeInBytes(Uint8List bytes) {
  late final String text;
  try {
    text = latin1.decode(bytes, allowInvalid: true);
  } catch (_) {
    return null;
  }
  final driveMatch = RegExp(
    r'[A-Za-z]:(?:\\[^\\/:*?"<>|\r\n]+)+?\.exe\b',
    caseSensitive: false,
  ).firstMatch(text);
  if (driveMatch != null) return _expandEnv(driveMatch.group(0)!);
  final envMatch = RegExp(
    r'%[^%\\/:*?"<>|\r\n]+%(?:\\[^\\/:*?"<>|\r\n]+)+?\.exe\b',
    caseSensitive: false,
  ).firstMatch(text);
  if (envMatch != null) return _expandEnv(envMatch.group(0)!);
  return null;
}

// --- UWP / Microsoft Store (optional) ---

List<_WinApp> _readUwpApps() {
  const script = r'''
$ErrorActionPreference = 'SilentlyContinue';
$deny = @(
  'Microsoft.Windows.ShellExperienceHost',
  'Microsoft.Windows.StartMenuExperienceHost',
  'Microsoft.Windows.Search',
  'MicrosoftWindows.Client.CBS',
  'Microsoft.Windows.CloudExperienceHost',
  'Microsoft.VCLibs*',
  'Microsoft.NET.*',
  'Microsoft.UI.Xaml*',
  'Microsoft.Services.Store.Engagement'
);
Get-AppxPackage | Where-Object {
  (-not $_.IsFramework) -and (-not $_.IsResourcePackage) -and
  ($_.InstallLocation -ne $null) -and ("$($_.InstallLocation)".Trim() -ne '')
} | ForEach-Object {
  $skip = $false;
  foreach ($pattern in $deny) { if ($_.Name -like $pattern) { $skip = $true; break } }
  if (-not $skip) { $_ }
} | Select-Object Name, PackageFullName, InstallLocation |
  ConvertTo-Json -Compress -Depth 2
''';
  try {
    final result = Process.runSync(
      'powershell',
      const [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
    );
    if (result.exitCode != 0) return [];
    final stdout = (result.stdout as String).trim();
    if (stdout.isEmpty) return [];
    final decoded = jsonDecode(stdout);
    final entries = decoded is List ? decoded : <Object?>[decoded];
    final apps = <_WinApp>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final name = (entry['Name']?.toString() ?? '').trim();
      final installLocation =
          (entry['InstallLocation']?.toString() ?? '').trim();
      if (name.isEmpty || installLocation.isEmpty) continue;
      // UWP executables are only routable when a real `.exe` exists in the
      // package folder (many packages are framework/resources for other apps).
      final exePath = _guessExeInDir(installLocation, name);
      if (exePath == null) continue;
      apps.add(
        _WinApp(
          name: name,
          exeName: p.basename(exePath),
          exePath: exePath,
        ),
      );
    }
    return apps;
  } catch (_) {
    return [];
  }
}

// --- Icons (best-effort) ---

/// Returns displayable image bytes for [ref] (a `DisplayIcon` reference or an
/// executable path), or `null` when extraction is not possible and the UI
/// should show a default icon.
Uint8List? _loadIconBytes(String ref) {
  try {
    var value = _stripQuotes(ref.trim());
    if (value.isEmpty) return null;
    final commaIndex = value.lastIndexOf(',');
    if (commaIndex > 0 &&
        RegExp(r'^,\d+$').hasMatch(value.substring(commaIndex))) {
      value = _stripQuotes(value.substring(0, commaIndex).trim());
    }
    value = _expandEnv(value);
    if (value.isEmpty) return null;
    final lower = value.toLowerCase();
    final file = File(value);
    if (!file.existsSync()) return null;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg')) {
      if (file.lengthSync() > 512 * 1024) return null;
      return file.readAsBytesSync();
    }
    if (lower.endsWith('.ico')) {
      if (file.lengthSync() > 1024 * 1024) return null;
      return _extractPngFromIco(file.readAsBytesSync());
    }
    // Icons embedded in `.exe`/`.dll` resources would require Win32 GDI
    // (`ExtractIconExW`/`SHGetFileInfoW` via `win32`/`ffi`) plus PNG
    // encoding; fall back to the default icon instead.
    return null;
  } catch (_) {
    return null;
  }
}

/// Extracts the largest PNG-compressed entry of an `.ico` file (Vista+
/// icons embed PNG data). Returns `null` for legacy BMP-only icon files.
Uint8List? _extractPngFromIco(Uint8List data) {
  try {
    if (data.length < 6) return null;
    final view = ByteData.sublistView(data);
    if (view.getUint16(0, Endian.little) != 0) return null;
    if (view.getUint16(2, Endian.little) != 1) return null;
    final count = view.getUint16(4, Endian.little);
    if (count == 0 || count > 100) return null;
    Uint8List? best;
    var bestLength = -1;
    var pos = 6;
    for (var i = 0; i < count; i++) {
      if (pos + 16 > data.length) break;
      final bytesInRes = view.getUint32(pos + 8, Endian.little);
      final imageOffset = view.getUint32(pos + 12, Endian.little);
      pos += 16;
      if (bytesInRes <= 0 ||
          imageOffset <= 0 ||
          imageOffset + bytesInRes > data.length) {
        continue;
      }
      final image = data.sublist(imageOffset, imageOffset + bytesInRes);
      if (image.length >= 8 &&
          image[0] == 0x89 &&
          image[1] == 0x50 &&
          image[2] == 0x4E &&
          image[3] == 0x47 &&
          image[4] == 0x0D &&
          image[5] == 0x0A &&
          image[6] == 0x1A &&
          image[7] == 0x0A) {
        if (bytesInRes > bestLength) {
          bestLength = bytesInRes;
          best = image;
        }
      }
    }
    return best;
  } catch (_) {
    return null;
  }
}

// --- Helpers ---

String _stripQuotes(String value) {
  var result = value.trim();
  if (result.length >= 2) {
    final first = result[0];
    final last = result[result.length - 1];
    if ((first == '"' && last == '"') ||
        (first == "'" && last == "'")) {
      result = result.substring(1, result.length - 1);
    }
  }
  return result;
}

/// Expands `%VAR%` segments (e.g. `%ProgramFiles%`,
/// `%ProgramFiles(x86)%`) using the current environment.
String _expandEnv(String value) {
  if (!value.contains('%')) return value;
  final upperEnv = <String, String>{};
  for (final entry in Platform.environment.entries) {
    upperEnv[entry.key.toUpperCase()] = entry.value;
  }
  return value.replaceAllMapped(
    RegExp('%([^%]+)%'),
    (match) => upperEnv[match.group(1)!.toUpperCase()] ?? match.group(0)!,
  );
}

bool _isWindowsPath(String path) {
  if (path.trim().isEmpty) return false;
  final lower = _expandEnv(path).toLowerCase();
  final systemRoot =
      (Platform.environment['SystemRoot'] ?? r'C:\Windows').toLowerCase();
  return lower.startsWith(systemRoot);
}
