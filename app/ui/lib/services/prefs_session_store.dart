import 'package:couchmates_core/couchmates_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the Hub address and device token in the app's preferences. The
/// last Hub address stays after signing out, to prefill the sign-in form.
class PrefsSessionStore implements SessionStore {
  static const _hub = 'couchmates.hub_url';
  static const _token = 'couchmates.device_token';
  static const _user = 'couchmates.username';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<StoredSession?> load() async {
    final p = await _prefs;
    final hub = p.getString(_hub);
    final token = p.getString(_token);
    if (hub == null || token == null) return null;
    return StoredSession(hubUrl: hub, token: token, username: p.getString(_user) ?? '');
  }

  @override
  Future<void> save(StoredSession session) async {
    final p = await _prefs;
    await p.setString(_hub, session.hubUrl);
    await p.setString(_token, session.token);
    await p.setString(_user, session.username);
  }

  @override
  Future<void> clear() async {
    final p = await _prefs;
    await p.remove(_token);
  }

  /// What to prefill on the sign-in screen.
  static Future<({String? hub, String? username})> lastUsed() async {
    final p = await SharedPreferences.getInstance();
    return (hub: p.getString(_hub), username: p.getString(_user));
  }
}
