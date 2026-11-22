import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../hub/api.dart';
import '../hub/hub_client.dart';
import '../social/photo.dart';
import '../stremio/addon_set.dart';
import '../stremio/models.dart';
import '../stremio/online_subtitles.dart';
import '../stremio/stremio_client.dart';

/// What's kept between launches: the Hub address and this device's token.
class StoredSession {
  const StoredSession({required this.hubUrl, required this.token, required this.username});

  final String hubUrl;
  final String token;
  final String username;
}

/// Where [HubSession] keeps the [StoredSession]. The app stores it on disk;
/// tests keep it in memory.
abstract interface class SessionStore {
  Future<StoredSession?> load();
  Future<void> save(StoredSession session);
  Future<void> clear();
}

class MemorySessionStore implements SessionStore {
  MemorySessionStore([this.session]);

  StoredSession? session;

  @override
  Future<StoredSession?> load() async => session;

  @override
  Future<void> save(StoredSession session) async => this.session = session;

  @override
  Future<void> clear() async => session = null;
}

enum SessionStatus { loading, signedOut, signedIn }

/// The signed-in user: their Hub, their config and their catalog.
///
/// [status] starts as [SessionStatus.loading] until [restore] finishes. When
/// the Hub can't be reached at start-up the session stays signed in with
/// [problem] set, so the user can retry without typing everything again.
class HubSession extends ChangeNotifier {
  HubSession({required SessionStore store, required this.deviceName, http.Client Function()? httpClient})
    : _store = store,
      _httpClient = httpClient ?? http.Client.new;

  final SessionStore _store;
  final http.Client Function() _httpClient;

  /// Shown to the admin in the user's device list.
  final String deviceName;

  SessionStatus _status = SessionStatus.loading;
  SessionStatus get status => _status;

  HubClient? _hub;
  HubClient? get hub => _hub;

  AppConfig? _config;
  AppConfig? get config => _config;

  StremioClient? _catalog;

  /// The user's catalog with the Hub's public add-ons (an [AddonSet]), once
  /// the config says where they are.
  StremioClient? get catalog => _catalog;

  /// The last problem worth showing, such as the Hub being unreachable.
  String? _problem;
  String? get problem => _problem;

  bool get voiceAvailable => _config?.voiceAvailable ?? false;

  /// Reads the saved session and checks it with the Hub.
  Future<void> restore() async {
    final saved = await _store.load();
    final url = saved == null ? null : parseHubAddress(saved.hubUrl);
    if (saved == null || url == null) {
      _set(SessionStatus.signedOut);
      return;
    }
    _hub = HubClient(baseUrl: url, token: saved.token, httpClient: _httpClient());
    _status = SessionStatus.signedIn;
    await refresh();
  }

  /// Fetches the config again. Signs out when the Hub no longer accepts the
  /// device.
  Future<void> refresh() async {
    final hub = _hub;
    if (hub == null) return;
    try {
      _applyConfig(await hub.config());
      _problem = null;
      await loadTrackers();
    } on HubException catch (e) {
      if (e.signedOut || e.status == 403) {
        await _forget(problem: e.message);
        return;
      }
      _problem = e.message;
    }
    notifyListeners();
  }

  /// Signs in. Throws [HubException] with a message to show on failure.
  Future<void> signIn({required String address, required String username, required String password}) async {
    final url = parseHubAddress(address);
    if (url == null) throw const HubException("That isn't a Hub address.");
    final hub = HubClient(baseUrl: url, httpClient: _httpClient());
    final login = await hub.login(LoginRequest(username: username.trim(), password: password, deviceName: deviceName));
    final config = await hub.config();
    await _store.save(StoredSession(hubUrl: url.toString(), token: login.token, username: login.user.username ?? ''));
    _hub?.close();
    _hub = hub;
    _applyConfig(config);
    _problem = null;
    _set(SessionStatus.signedIn);
    await loadTrackers();
  }

  /// Signs this device out on the Hub (best effort) and forgets it here.
  Future<void> signOut() async {
    try {
      await _hub?.logout();
    } on HubException {
      // Forget it locally anyway; the admin can remove the device.
    }
    await _forget();
  }

  /// Changes the password; the Hub signs out the user's other devices.
  Future<void> changePassword({required String current, required String next}) async {
    final hub = _hub;
    if (hub == null) throw const HubException('Sign in first.');
    await hub.changePassword(PasswordChangeRequest(currentPassword: current, newPassword: next));
  }

  /// A LiveKit token for the voice room of watch party room [roomCode].
  Future<VoiceTokenResponse> voiceToken(String roomCode) async {
    final hub = _hub;
    if (hub == null) throw const HubException('Sign in first.');
    try {
      return await hub.voiceToken(roomCode);
    } on HubException catch (e) {
      if (e.signedOut) await _forget(problem: e.message);
      rethrow;
    }
  }

  /// Whether a newer app than [version] is out.
  Future<UpdateInfo> checkForUpdate({required String platform, required String version}) async {
    final hub = _hub;
    if (hub == null) throw const HubException('Sign in first.');
    return hub.update(platform: platform, version: version);
  }

  Future<UpdateDownload> updateDownload(String platform) async {
    final hub = _hub;
    if (hub == null) throw const HubException('Sign in first.');
    return hub.updateDownload(platform);
  }

  List<TrackerStatus> _trackers = const [];

  /// The tracker services and whether this user linked them; refreshed by
  /// [loadTrackers].
  List<TrackerStatus> get trackers => _trackers;
  bool get anyTrackerLinked => _trackers.any((t) => t.linked);

  Future<void> loadTrackers() async {
    final hub = _hub;
    if (hub == null) return;
    try {
      _trackers = (await hub.trackers()).trackers;
      notifyListeners();
    } on HubException {
      // Keep what we had; trackers are optional.
    }
  }

  Future<TrackerLinkStart> startTrackerLink(String service) => _require().trackerLink(service);

  Future<TrackerLinkPoll> pollTrackerLink(String service) async {
    final poll = await _require().trackerPoll(service);
    if (poll.status == 'linked') await loadTrackers();
    return poll;
  }

  Future<void> unlinkTracker(String service) async {
    await _require().trackerUnlink(service);
    await loadTrackers();
  }

  /// Sends [request] to the linked trackers through the Hub. Never throws:
  /// scrobbling must not get in the way of watching.
  Future<void> scrobble(ScrobbleRequest request) async {
    if (!anyTrackerLinked) return;
    try {
      await _hub?.scrobble(request);
    } catch (_) {}
  }

  final Map<String, Future<Credits>> _credits = {};

  /// Cast and crew for [meta], from TMDB when the Hub has a key, otherwise
  /// [Credits.none]. Remembered for the session.
  Future<Credits> credits(StremioMeta meta) {
    final hub = _hub;
    if (hub == null) return Future.value(Credits.none);
    final imdb = meta.id.startsWith('tt') ? meta.id : null;
    if (meta.tmdbId == null && imdb == null) return Future.value(Credits.none);
    return _credits.putIfAbsent(
      '${meta.type}/${meta.id}',
      () => hub.credits(type: meta.type, tmdbId: meta.tmdbId, imdb: imdb).catchError((Object _) => Credits.none),
    );
  }

  Future<Profile> profile() => _require().profile();

  /// Changes the display name others see; the config follows.
  Future<Profile> rename(String name) async {
    final profile = await _require().rename(name);
    await refresh();
    return profile;
  }

  /// Sets the profile picture from a picked file: turned upright, cropped to
  /// a square and shrunk before it's sent. The config follows.
  Future<Profile> setPhoto(Uint8List file) async {
    final hub = _require();
    final jpeg = await preparePhotoInBackground(file);
    if (jpeg == null) throw const HubException("That file isn't a picture Couchmates can read.");
    final profile = await hub.uploadPhoto(jpeg);
    await refresh();
    return profile;
  }

  Future<Profile> removePhoto() async {
    final profile = await _require().removePhoto();
    await refresh();
    return profile;
  }

  /// Where to fetch a picture [path] from the Hub, with [photoHeaders].
  Uri? photoUrl(String? path) => path == null ? null : _hub?.photoUrl(path);
  Map<String, String> get photoHeaders => _hub?.authHeaders ?? const {};

  /// Signs out another of this user's devices.
  Future<void> signOutDevice(String deviceId) => _require().signOutDevice(deviceId);

  HubClient _require() {
    final hub = _hub;
    if (hub == null) throw const HubException('Sign in first.');
    return hub;
  }

  /// What the catalog is built from, to rebuild it only when that changes.
  static String _sources(AppConfig? c) =>
      [c?.addon?.baseUrl ?? '', for (final a in c?.addons ?? const <ExtraAddon>[]) '${a.id}=${a.baseUrl}'].join(' ');

  void _applyConfig(AppConfig config) {
    final changed = _sources(_config) != _sources(config);
    _config = config;
    if (changed) {
      _catalog?.close();
      final addon = config.addon;
      _catalog = addon == null && config.addons.isEmpty
          ? null
          : AddonSet(
              primary: addon == null ? null : StremioClient(baseUrl: addon.baseUrl, httpClient: _httpClient()),
              extras: [
                for (final a in config.addons)
                  ExtraSource(
                    id: a.id,
                    name: a.name,
                    client: StremioClient(
                      baseUrl: a.baseUrl,
                      httpClient: _httpClient(),
                      name: a.name,
                      strictStreams: false,
                    ),
                  ),
              ],
              fallbackSubtitles: StremioClient(
                baseUrl: openSubtitlesAddon,
                httpClient: _httpClient(),
                name: 'OpenSubtitles',
              ),
            );
    }
  }

  Future<void> _forget({String? problem}) async {
    await _store.clear();
    _hub?.close();
    _catalog?.close();
    _hub = null;
    _catalog = null;
    _config = null;
    _trackers = const [];
    _problem = problem;
    _set(SessionStatus.signedOut);
  }

  void _set(SessionStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _hub?.close();
    _catalog?.close();
    super.dispose();
  }
}
