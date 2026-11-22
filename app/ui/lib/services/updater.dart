import 'dart:async';
import 'dart:io';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Checks the Hub for a newer app and installs it (Windows only for now).
class Updater extends ChangeNotifier {
  Updater({required this.session, required this.settings});

  final HubSession session;
  final AppSettings settings;

  /// The platform name the Hub knows, or null where updating isn't supported.
  static String? get platform => !kIsWeb && Platform.isWindows ? 'windows' : null;

  String? _version;
  String? get version => _version;

  UpdateInfo? _info;
  UpdateInfo? get info => _info;
  bool get updateReady => _info?.newer ?? false;

  bool _checking = false;
  bool get checking => _checking;

  /// 0–1 while downloading.
  double? _progress;
  double? get progress => _progress;

  String? _error;
  String? get error => _error;

  /// The user said "Later" to this version; don't nag again this run.
  String? _dismissed;
  bool get showBanner => updateReady && _info?.latestVersion != _dismissed && _progress == null;

  bool _checkedOnStart = false;

  Future<String> _currentVersion() async => _version ??= (await PackageInfo.fromPlatform()).version;

  /// Called once per launch after signing in, when the setting is on.
  Future<void> checkOnStart() async {
    if (_checkedOnStart || !settings.get(Settings.checkUpdates)) return;
    _checkedOnStart = true;
    await check();
  }

  Future<void> check() async {
    final p = platform;
    if (p == null || _checking) return;
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      _info = await session.checkForUpdate(platform: p, version: await _currentVersion());
    } on HubException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = "Couldn't check for updates.";
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  void dismiss() {
    _dismissed = _info?.latestVersion;
    notifyListeners();
  }

  /// Downloads the installer, starts it and quits; the installer reopens the
  /// app when it's done. Returns only on failure, with [error] set.
  Future<void> install() async {
    final p = platform;
    if (p == null || _progress != null) return;
    _error = null;
    _progress = 0;
    notifyListeners();
    try {
      final download = await session.updateDownload(p);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}${download.fileName}');
      final client = http.Client();
      try {
        final response = await client.send(http.Request('GET', Uri.parse(download.url)));
        if (response.statusCode != 200) throw HttpException('download failed (${response.statusCode})');
        final total = response.contentLength ?? _info?.sizeBytes;
        final sink = file.openWrite();
        var received = 0;
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) {
            _progress = received / total;
            notifyListeners();
          }
        }
        await sink.close();
      } finally {
        client.close();
      }
      // Inno Setup: no wizard, no prompts; it closes nothing itself, so quit
      // right after starting it. Its last step reopens Couchmates.
      await Process.start(file.path, ['/SILENT', '/SUPPRESSMSGBOXES', '/NOCANCEL'], mode: ProcessStartMode.detached);
      exit(0);
    } on HubException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = "Couldn't download the update. Try again later.";
    }
    _progress = null;
    notifyListeners();
  }
}
