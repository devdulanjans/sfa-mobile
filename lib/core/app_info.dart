import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// App version + build number, sourced from pubspec.yaml at build time
/// (no need to keep a separate hardcoded string in sync).
final appInfoProvider = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});
