import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api.dart';

/// Why a Hub call failed. [message] is a sentence the app can show as is.
class HubException implements Exception {
  const HubException(this.message, {this.status});

  final String message;

  /// The HTTP status, or null when the Hub couldn't be reached.
  final int? status;

  /// The device token is no longer valid; the user has to sign in again.
  bool get signedOut => status == 401;

  @override
  String toString() => 'HubException($status): $message';
}

/// Normalizes what the user typed as the Hub address: adds `https://` when
/// no scheme is given and drops a trailing slash. Null if it isn't a URL.
Uri? parseHubAddress(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty) return null;
  final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
  return uri.replace(path: path, query: null, fragment: null);
}

/// The Hub's app API.
class HubClient {
  HubClient({required this.baseUrl, this.token, http.Client? httpClient, this.timeout = const Duration(seconds: 20)})
    : _http = httpClient ?? http.Client();

  final Uri baseUrl;

  /// The device token from [login]; sent with every signed-in call.
  String? token;
  final Duration timeout;
  final http.Client _http;

  /// [path] may carry a query (`/a?b=c`).
  Uri _url(String path) {
    final q = path.indexOf('?');
    return baseUrl.replace(
      path: '${baseUrl.path}${q < 0 ? path : path.substring(0, q)}',
      query: q < 0 ? null : path.substring(q + 1),
    );
  }

  Future<Json> _send(String method, String path, {Json? body}) async {
    final request = http.Request(method, _url(path));
    request.headers['accept'] = 'application/json';
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(timeout));
    } catch (e) {
      throw HubException("Couldn't reach the Hub. Check the address and your connection.");
    }
    Json? json;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Json) json = decoded;
    } catch (_) {}
    if (response.statusCode >= 200 && response.statusCode < 300 && json != null) return json;
    final message = json?['error'] as String? ?? 'The Hub answered with an error (${response.statusCode}).';
    throw HubException(message, status: response.statusCode);
  }

  /// Signs in and keeps the device token in [token].
  Future<LoginResponse> login(LoginRequest request) async {
    final response = LoginResponse.fromJson(await _send('POST', HubPaths.login, body: request.toJson()));
    token = response.token;
    return response;
  }

  Future<AppConfig> config() async => AppConfig.fromJson(await _send('GET', HubPaths.config));

  Future<VoiceTokenResponse> voiceToken(String roomCode) async => VoiceTokenResponse.fromJson(
    await _send('POST', HubPaths.voiceToken, body: VoiceTokenRequest(room: roomCode).toJson()),
  );

  Future<void> changePassword(PasswordChangeRequest request) async {
    await _send('POST', HubPaths.password, body: request.toJson());
  }

  /// Signs this device out. Clears [token] even when the Hub can't be reached.
  Future<void> logout() async {
    try {
      await _send('POST', HubPaths.logout);
    } finally {
      token = null;
    }
  }

  /// Whether a newer app than [version] is out for [platform].
  Future<UpdateInfo> update({required String platform, required String version}) async => UpdateInfo.fromJson(
    await _send(
      'GET',
      '${HubPaths.update}?platform=${Uri.encodeQueryComponent(platform)}&version=${Uri.encodeQueryComponent(version)}',
    ),
  );

  /// A short-lived link to the newest installer for [platform].
  Future<UpdateDownload> updateDownload(String platform) async => UpdateDownload.fromJson(
    await _send('POST', HubPaths.updateDownload, body: UpdateDownloadRequest(platform: platform).toJson()),
  );

  Future<TrackersResponse> trackers() async => TrackersResponse.fromJson(await _send('GET', HubPaths.trackers));

  Future<TrackerLinkStart> trackerLink(String service) async => TrackerLinkStart.fromJson(
    await _send('POST', HubPaths.trackersLink, body: TrackerRequest(service: service).toJson()),
  );

  Future<TrackerLinkPoll> trackerPoll(String service) async => TrackerLinkPoll.fromJson(
    await _send('POST', HubPaths.trackersPoll, body: TrackerRequest(service: service).toJson()),
  );

  Future<void> trackerUnlink(String service) async {
    await _send('POST', HubPaths.trackersUnlink, body: TrackerRequest(service: service).toJson());
  }

  Future<void> scrobble(ScrobbleRequest request) async {
    await _send('POST', HubPaths.scrobble, body: request.toJson());
  }

  /// Cast and crew from TMDB through the Hub. [type] is the catalog type.
  Future<Credits> credits({required String type, int? tmdbId, String? imdb}) async {
    final query = [
      'type=${Uri.encodeQueryComponent(type)}',
      if (tmdbId != null) 'tmdb=$tmdbId',
      if (imdb != null) 'imdb=${Uri.encodeQueryComponent(imdb)}',
    ].join('&');
    return Credits.fromJson(await _send('GET', '${HubPaths.credits}?$query'));
  }

  Future<Profile> profile() async => Profile.fromJson(await _send('GET', HubPaths.profile));

  Future<Profile> rename(String name) async =>
      Profile.fromJson(await _send('POST', HubPaths.profile, body: ProfileUpdate(name: name).toJson()));

  Future<void> signOutDevice(String deviceId) async {
    await _send('POST', HubPaths.deviceSignOut, body: DeviceSignOut(deviceId: deviceId).toJson());
  }

  /// Sets the profile picture to [jpeg], already cropped and shrunk.
  Future<Profile> uploadPhoto(Uint8List jpeg) async => Profile.fromJson(
    await _send('POST', HubPaths.profilePhoto, body: ProfilePhotoUpload(image: base64Encode(jpeg)).toJson()),
  );

  Future<Profile> removePhoto() async => Profile.fromJson(await _send('POST', HubPaths.profilePhotoRemove));

  /// The full address of a picture [path] from the Hub, such as a person's
  /// `photo`. Fetch it with [authHeaders].
  Uri photoUrl(String path) => _url(path);

  /// Headers that let a plain image request through, such as a picture's.
  Map<String, String> get authHeaders => {if (token != null) 'authorization': 'Bearer $token'};

  /// A file's tracks as someone on this Hub read them, or null when nobody
  /// has yet. [key] is the file's [fileKey].
  Future<List<FileTrack>?> fileTracks(String key) async =>
      FileTracks.fromJson(await _send('GET', '${HubPaths.tracks}?key=${Uri.encodeQueryComponent(key)}')).tracks;

  /// Shares a file's tracks with everyone on this Hub.
  Future<void> saveFileTracks(String key, List<FileTrack> tracks) async {
    await _send(
      'POST',
      HubPaths.tracks,
      body: FileTracksUpload(key: key, tracks: tracks).toJson(),
    );
  }

  /// Says what this device plays (or that the app is open), and gets what
  /// everyone else is up to.
  Future<Activity> presence(NowWatching? watching) async =>
      Activity.fromJson(await _send('POST', HubPaths.presence, body: PresenceUpdate(watching: watching).toJson()));

  Future<Activity> askToJoin(String userId) async =>
      Activity.fromJson(await _send('POST', HubPaths.joinRequests, body: JoinRequestCreate(toUserId: userId).toJson()));

  Future<Activity> answerJoinRequest(String id, {required bool accept, String? room}) async => Activity.fromJson(
    await _send(
      'POST',
      HubPaths.joinRequestsAnswer,
      body: JoinRequestAnswer(id: id, accept: accept, room: room).toJson(),
    ),
  );

  Future<Activity> cancelJoinRequest(String id) async =>
      Activity.fromJson(await _send('POST', HubPaths.joinRequestsCancel, body: JoinRequestCancel(id: id).toJson()));

  Future<ChatOverview> chatChannels() async => ChatOverview.fromJson(await _send('GET', HubPaths.chat));

  /// A page of [channel]: the latest, those [before] a message id, or those
  /// [after] one.
  Future<ChatMessages> chatMessages(String channel, {int? before, int? after}) async {
    final query = [
      'channel=${Uri.encodeQueryComponent(channel)}',
      if (before != null) 'before=$before',
      if (after != null) 'after=$after',
    ].join('&');
    return ChatMessages.fromJson(await _send('GET', '${HubPaths.chatMessages}?$query'));
  }

  Future<ChatMessage> sendChat(String channel, String text) async => ChatMessage.fromJson(
    await _send(
      'POST',
      HubPaths.chatSend,
      body: ChatSend(channel: channel, text: text).toJson(),
    ),
  );

  Future<void> markChatRead(String channel, int upTo) async {
    await _send(
      'POST',
      HubPaths.chatRead,
      body: ChatRead(channel: channel, upTo: upTo).toJson(),
    );
  }

  /// The live chat socket's address (`ws:` or `wss:`); open it with
  /// [authHeaders].
  Uri get chatLiveUrl {
    final url = _url(HubPaths.chatLive);
    return url.replace(scheme: url.scheme == 'https' ? 'wss' : 'ws');
  }

  void close() => _http.close();
}
