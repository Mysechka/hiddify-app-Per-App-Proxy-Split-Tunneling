import 'dart:typed_data';

class AppPackageInfo {
  const AppPackageInfo({
    required this.packageName,
    required this.name,
    required this.icon,
    this.isSystem = false,
  });

  final String packageName;
  final String name;
  final Uint8List? icon;
  final bool isSystem;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppPackageInfo &&
          runtimeType == other.runtimeType &&
          packageName == other.packageName;

  @override
  int get hashCode => packageName.hashCode;
}
