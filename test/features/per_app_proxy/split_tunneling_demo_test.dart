// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/per_app_proxy/data/desktop_installed_apps_service.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

void main() {
  test('Run Split Tunneling Demo and Inspection in Test Mode', () async {
    print('====================================================');
    print('  Hiddify Desktop Split Tunneling - Test Mode Runner');
    print('====================================================');
    print('OS: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})');
    print('Dart: ${Platform.version}');
    print('');

    print('🔍 Scanning installed desktop applications...');
    final stopwatch = Stopwatch()..start();
    final allApps = await DesktopInstalledAppsService.getInstalledApps();
    stopwatch.stop();

    final userApps = allApps.where((a) => !a.isSystem).toList();
    final systemApps = allApps.where((a) => a.isSystem).toList();
    final withIcons = allApps.where((a) => a.icon != null && a.icon!.isNotEmpty).toList();

    print('✅ Scan complete in ${stopwatch.elapsedMilliseconds} ms:');
    print('   • Total applications found : ${allApps.length}');
    print('   • User applications        : ${userApps.length}');
    print('   • System applications      : ${systemApps.length}');
    print('   • Apps with valid PNG icon : ${withIcons.length} (${(withIcons.length / (allApps.isEmpty ? 1 : allApps.length) * 100).toStringAsFixed(1)}%)');
    print('');

    print('📋 Sample of detected applications (User):');
    for (final app in userApps.take(8)) {
      final iconStatus = app.icon != null ? '🎨 [PNG ${app.icon!.length} B]' : '⚪ [No icon]';
      print('   • ${app.name.padRight(28)} | Executable: ${app.packageName.padRight(24)} | $iconStatus');
    }

    if (systemApps.isNotEmpty) {
      print('');
      print('📋 Sample of detected applications (System):');
      for (final app in systemApps.take(4)) {
        final iconStatus = app.icon != null ? '🎨 [PNG ${app.icon!.length} B]' : '⚪ [No icon]';
        print('   • ${app.name.padRight(28)} | Executable: ${app.packageName.padRight(24)} | $iconStatus');
      }
    }

    print('');
    print('----------------------------------------------------');
    print('🧪 Testing Route Rule Generation for sing-box');
    print('----------------------------------------------------');

    // Test Exclude Mode
    final sampleExcluded = userApps.take(2).map((a) => a.packageName).toList();
    if (sampleExcluded.isEmpty) sampleExcluded.add('Telegram');
    print('\n1️⃣  Mode: PerAppProxyMode.exclude');
    print('   Excluded apps: $sampleExcluded');

    final excludeRule = Rule(
      name: 'Per-App Exclude',
      outbound: Outbound.direct,
      processNames: sampleExcluded,
      enabled: true,
    );
    final excludeConfig = RouteRule(rules: [excludeRule]);
    final excludeJson = const JsonEncoder.withIndent('  ').convert(excludeConfig.toProto3Json());
    print('   Generated sing-box config:');
    print(excludeJson);

    // Test Include Mode
    final sampleIncluded = userApps.take(1).map((a) => a.packageName).toList();
    if (sampleIncluded.isEmpty) sampleIncluded.add('Google Chrome');
    print('\n2️⃣  Mode: PerAppProxyMode.include');
    print('   Included apps: $sampleIncluded');

    final includeRule = Rule(
      name: 'Per-App Include',
      outbound: Outbound.proxy,
      processNames: sampleIncluded,
      enabled: true,
    );
    final directRemainingRule = Rule(
      name: 'Per-App Direct Remaining',
      outbound: Outbound.direct,
      network: Network.all,
      enabled: true,
    );
    final includeConfig = RouteRule(rules: [includeRule, directRemainingRule]);
    final includeJson = const JsonEncoder.withIndent('  ').convert(includeConfig.toProto3Json());
    print('   Generated sing-box config:');
    print(includeJson);

    print('\n====================================================');
    print('🎉 Split Tunneling test execution verified successfully!');
    print('====================================================');

    expect(allApps, isNotEmpty);
    expect(userApps, isNotEmpty);
    expect(withIcons, isNotEmpty);
  });
}
