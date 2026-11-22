import 'package:couchmates_core/couchmates_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings and watch progress in the app's preferences file, under keys
/// prefixed `s.` so they don't mix with the session.
class PrefsSettingsStore implements SettingsStore {
  static const _prefix = 's.';

  @override
  Future<Map<String, Object>> load() async {
    final p = await SharedPreferences.getInstance();
    return {
      for (final k in p.getKeys())
        if (k.startsWith(_prefix) && p.get(k) != null) k.substring(_prefix.length): p.get(k)!,
    };
  }

  @override
  Future<void> write(String key, Object? value) async {
    final p = await SharedPreferences.getInstance();
    final k = '$_prefix$key';
    switch (value) {
      case null:
        await p.remove(k);
      case final bool v:
        await p.setBool(k, v);
      case final int v:
        await p.setInt(k, v);
      case final double v:
        await p.setDouble(k, v);
      case final String v:
        await p.setString(k, v);
      default:
        throw ArgumentError('Unsupported setting value: $value');
    }
  }
}
