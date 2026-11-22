import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// A name for this device in the admin's device list, such as
/// "Couchmates on LIVING-ROOM" or "Couchmates on Pixel 8".
Future<String> deviceName() async {
  String? name;
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isWindows) {
      name = (await info.windowsInfo).computerName;
    } else if (Platform.isAndroid) {
      final a = await info.androidInfo;
      name = a.model;
    } else if (Platform.isMacOS) {
      name = (await info.macOsInfo).computerName;
    } else if (Platform.isLinux) {
      name = (await info.linuxInfo).prettyName;
    }
  } catch (_) {
    name = null;
  }
  name ??= Platform.localHostname;
  return name.trim().isEmpty ? 'Couchmates app' : 'Couchmates on ${name.trim()}';
}
