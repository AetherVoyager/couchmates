/// The app API shapes. Mirrors `core/src/api.rs`; see there for each call.
library;

import '../rules.dart';

typedef Json = Map<String, dynamic>;

abstract final class HubPaths {
  static const login = '/api/app/login';
  static const config = '/api/app/config';
  static const voiceToken = '/api/app/voice-token';
  static const password = '/api/app/password';
  static const logout = '/api/app/logout';
  static const update = '/api/app/update';
  static const updateDownload = '/api/app/update/download';
  static const trackers = '/api/app/trackers';
  static const trackersLink = '/api/app/trackers/link';
  static const trackersPoll = '/api/app/trackers/poll';
  static const trackersUnlink = '/api/app/trackers/unlink';
  static const scrobble = '/api/app/scrobble';
  static const credits = '/api/app/credits';
  static const profile = '/api/app/profile';
  static const deviceSignOut = '/api/app/devices/sign-out';
  static const profilePhoto = '/api/app/profile/photo';
  static const profilePhotoRemove = '/api/app/profile/photo/remove';
  static const presence = '/api/app/presence';
  static const joinRequests = '/api/app/join-requests';
  static const joinRequestsAnswer = '/api/app/join-requests/answer';
  static const joinRequestsCancel = '/api/app/join-requests/cancel';
  static const tracks = '/api/app/tracks';
  static const chat = '/api/app/chat';
  static const chatMessages = '/api/app/chat/messages';
  static const chatSend = '/api/app/chat/send';
  static const chatRead = '/api/app/chat/read';
  static const chatLive = '/api/app/chat/live';
}

class LoginRequest {
  const LoginRequest({required this.username, required this.password, this.deviceName});

  final String username;
  final String password;
  final String? deviceName;

  factory LoginRequest.fromJson(Json j) => LoginRequest(
    username: j['username'] as String,
    password: j['password'] as String,
    deviceName: j['device_name'] as String?,
  );

  Json toJson() => {'username': username, 'password': password, 'device_name': ?deviceName};
}

class UserInfo {
  const UserInfo({required this.id, required this.name, this.username, this.photo});

  final String id;
  final String name;
  final String? username;

  /// The profile picture's path under the Hub, fetched with the device token.
  final String? photo;

  factory UserInfo.fromJson(Json j) => UserInfo(
    id: j['id'] as String,
    name: j['name'] as String,
    username: j['username'] as String?,
    photo: j['photo'] as String?,
  );

  Json toJson() => {'id': id, 'name': name, 'username': username, 'photo': ?photo};
}

class LoginResponse {
  const LoginResponse({required this.token, required this.user});

  final String token;
  final UserInfo user;

  factory LoginResponse.fromJson(Json j) =>
      LoginResponse(token: j['token'] as String, user: UserInfo.fromJson(j['user'] as Json));

  Json toJson() => {'token': token, 'user': user.toJson()};
}

class DeviceInfo {
  const DeviceInfo({required this.id, required this.name});

  final String id;
  final String name;

  factory DeviceInfo.fromJson(Json j) => DeviceInfo(id: j['id'] as String, name: j['name'] as String);

  Json toJson() => {'id': id, 'name': name};
}

class AddonInfo {
  const AddonInfo({required this.baseUrl, required this.manifestUrl});

  /// `<baseUrl>/catalog/…`, `/meta/…` and `/stream/…` follow the Stremio
  /// addon protocol.
  final String baseUrl;
  final String manifestUrl;

  factory AddonInfo.fromJson(Json j) =>
      AddonInfo(baseUrl: j['base_url'] as String, manifestUrl: j['manifest_url'] as String);

  Json toJson() => {'base_url': baseUrl, 'manifest_url': manifestUrl};
}

class AppConfig {
  const AppConfig({required this.user, required this.device, required this.addon, required this.voiceAvailable});

  final UserInfo user;
  final DeviceInfo device;

  /// The user's catalog. Null until the admin connects Telegram-Stremio.
  final AddonInfo? addon;
  final bool voiceAvailable;

  factory AppConfig.fromJson(Json j) => AppConfig(
    user: UserInfo.fromJson(j['user'] as Json),
    device: DeviceInfo.fromJson(j['device'] as Json),
    addon: j['addon'] == null ? null : AddonInfo.fromJson(j['addon'] as Json),
    voiceAvailable: (j['voice'] as Json)['available'] as bool,
  );

  Json toJson() => {
    'user': user.toJson(),
    'device': device.toJson(),
    'addon': addon?.toJson(),
    'voice': {'available': voiceAvailable},
  };
}

class VoiceTokenRequest {
  const VoiceTokenRequest({required this.room});

  /// The watch party room code.
  final String room;

  factory VoiceTokenRequest.fromJson(Json j) => VoiceTokenRequest(room: j['room'] as String);

  Json toJson() => {'room': room};
}

class VoiceTokenResponse {
  const VoiceTokenResponse({required this.url, required this.token, required this.room});

  final String url;
  final String token;
  final String room;

  factory VoiceTokenResponse.fromJson(Json j) =>
      VoiceTokenResponse(url: j['url'] as String, token: j['token'] as String, room: j['room'] as String);

  Json toJson() => {'url': url, 'token': token, 'room': room};
}

class PasswordChangeRequest {
  const PasswordChangeRequest({required this.currentPassword, required this.newPassword});

  final String currentPassword;
  final String newPassword;

  factory PasswordChangeRequest.fromJson(Json j) =>
      PasswordChangeRequest(currentPassword: j['current_password'] as String, newPassword: j['new_password'] as String);

  Json toJson() => {'current_password': currentPassword, 'new_password': newPassword};
}

class OkResponse {
  const OkResponse({required this.ok});

  final bool ok;

  factory OkResponse.fromJson(Json j) => OkResponse(ok: j['ok'] as bool);

  Json toJson() => {'ok': ok};
}

class ErrorResponse {
  const ErrorResponse({required this.error});

  final String error;

  factory ErrorResponse.fromJson(Json j) => ErrorResponse(error: j['error'] as String);

  Json toJson() => {'error': error};
}

class UpdateInfo {
  const UpdateInfo({required this.available, required this.newer, this.latestVersion, this.notes, this.sizeBytes});

  /// False when the Hub has no GitHub access set up, or no release has an
  /// installer for this platform.
  final bool available;

  /// [latestVersion] is newer than the version the app sent.
  final bool newer;
  final String? latestVersion;
  final String? notes;
  final int? sizeBytes;

  factory UpdateInfo.fromJson(Json j) => UpdateInfo(
    available: j['available'] as bool,
    newer: j['newer'] as bool,
    latestVersion: j['latest_version'] as String?,
    notes: j['notes'] as String?,
    sizeBytes: j['size_bytes'] as int?,
  );

  Json toJson() => {
    'available': available,
    'latest_version': latestVersion,
    'newer': newer,
    'notes': notes,
    'size_bytes': sizeBytes,
  };
}

class UpdateDownloadRequest {
  const UpdateDownloadRequest({required this.platform});

  final String platform;

  factory UpdateDownloadRequest.fromJson(Json j) => UpdateDownloadRequest(platform: j['platform'] as String);

  Json toJson() => {'platform': platform};
}

class UpdateDownload {
  const UpdateDownload({required this.url, required this.version, required this.fileName});

  /// A short-lived link; fetch it without any headers.
  final String url;
  final String version;
  final String fileName;

  factory UpdateDownload.fromJson(Json j) =>
      UpdateDownload(url: j['url'] as String, version: j['version'] as String, fileName: j['file_name'] as String);

  Json toJson() => {'url': url, 'version': version, 'file_name': fileName};
}

class TrackerStatus {
  const TrackerStatus({required this.service, required this.available, required this.linked, this.username});

  /// `trakt` or `simkl`.
  final String service;
  final bool available;
  final bool linked;
  final String? username;

  String get label => service == 'trakt' ? 'Trakt' : (service == 'simkl' ? 'Simkl' : service);

  factory TrackerStatus.fromJson(Json j) => TrackerStatus(
    service: j['service'] as String,
    available: j['available'] as bool,
    linked: j['linked'] as bool,
    username: j['username'] as String?,
  );

  Json toJson() => {'service': service, 'available': available, 'linked': linked, 'username': username};
}

class TrackersResponse {
  const TrackersResponse({required this.trackers});

  final List<TrackerStatus> trackers;

  factory TrackersResponse.fromJson(Json j) =>
      TrackersResponse(trackers: [for (final t in j['trackers'] as List) TrackerStatus.fromJson(t as Json)]);

  Json toJson() => {
    'trackers': [for (final t in trackers) t.toJson()],
  };
}

class TrackerRequest {
  const TrackerRequest({required this.service});

  final String service;

  factory TrackerRequest.fromJson(Json j) => TrackerRequest(service: j['service'] as String);

  Json toJson() => {'service': service};
}

class TrackerLinkStart {
  const TrackerLinkStart({
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String userCode;
  final String verificationUrl;
  final int expiresIn;
  final int interval;

  factory TrackerLinkStart.fromJson(Json j) => TrackerLinkStart(
    userCode: j['user_code'] as String,
    verificationUrl: j['verification_url'] as String,
    expiresIn: j['expires_in'] as int,
    interval: j['interval'] as int,
  );

  Json toJson() => {
    'user_code': userCode,
    'verification_url': verificationUrl,
    'expires_in': expiresIn,
    'interval': interval,
  };
}

class TrackerLinkPoll {
  const TrackerLinkPoll({required this.status, this.username});

  /// `pending`, `linked`, `expired` or `denied`.
  final String status;
  final String? username;

  factory TrackerLinkPoll.fromJson(Json j) =>
      TrackerLinkPoll(status: j['status'] as String, username: j['username'] as String?);

  Json toJson() => {'status': status, 'username': username};
}

class ScrobbleRequest {
  const ScrobbleRequest({
    required this.action,
    required this.kind,
    required this.imdb,
    required this.progress,
    this.season,
    this.episode,
  });

  /// `start`, `pause` or `stop`.
  final String action;

  /// `movie` or `episode`.
  final String kind;
  final String imdb;
  final int? season;
  final int? episode;

  /// Percent watched, 0–100.
  final double progress;

  factory ScrobbleRequest.fromJson(Json j) => ScrobbleRequest(
    action: j['action'] as String,
    kind: j['kind'] as String,
    imdb: j['imdb'] as String,
    season: j['season'] as int?,
    episode: j['episode'] as int?,
    progress: (j['progress'] as num).toDouble(),
  );

  Json toJson() => {
    'action': action,
    'kind': kind,
    'imdb': imdb,
    'season': ?season,
    'episode': ?episode,
    'progress': progress,
  };
}

class CastMember {
  const CastMember({required this.name, this.character, this.photo});

  final String name;
  final String? character;
  final String? photo;

  factory CastMember.fromJson(Json j) =>
      CastMember(name: j['name'] as String, character: j['character'] as String?, photo: j['photo'] as String?);

  Json toJson() => {'name': name, 'character': character, 'photo': photo};
}

/// A trailer or featurette on YouTube.
class Extra {
  const Extra({required this.name, required this.kind, required this.youtube});

  final String name;

  /// `Trailer`, `Teaser`, `Featurette`…
  final String kind;
  final String youtube;

  Uri get url => Uri.parse('https://www.youtube.com/watch?v=$youtube');
  String get thumbnail => 'https://img.youtube.com/vi/$youtube/mqdefault.jpg';

  factory Extra.fromJson(Json j) =>
      Extra(name: j['name'] as String, kind: j['kind'] as String, youtube: j['youtube'] as String);

  Json toJson() => {'name': name, 'kind': kind, 'youtube': youtube};
}

class Credits {
  const Credits({
    required this.available,
    this.cast = const [],
    this.directors = const [],
    this.writers = const [],
    this.tagline,
    this.certification,
    this.studios = const [],
    this.countries = const [],
    this.released,
    this.videos = const [],
  });

  static const none = Credits(available: false);

  /// False when the Hub has no TMDB key or TMDB doesn't know the title.
  final bool available;
  final List<CastMember> cast;
  final List<String> directors;
  final List<String> writers;
  final String? tagline;

  /// Age rating, such as `PG-13`.
  final String? certification;
  final List<String> studios;
  final List<String> countries;

  /// `YYYY-MM-DD`.
  final String? released;
  final List<Extra> videos;

  factory Credits.fromJson(Json j) => Credits(
    available: j['available'] as bool,
    cast: [for (final c in j['cast'] as List) CastMember.fromJson(c as Json)],
    directors: (j['directors'] as List).cast<String>(),
    writers: (j['writers'] as List).cast<String>(),
    tagline: j['tagline'] as String?,
    certification: j['certification'] as String?,
    studios: ((j['studios'] as List?) ?? const []).cast<String>(),
    countries: ((j['countries'] as List?) ?? const []).cast<String>(),
    released: j['released'] as String?,
    videos: [for (final v in (j['videos'] as List?) ?? const []) Extra.fromJson(v as Json)],
  );

  Json toJson() => {
    'available': available,
    'cast': [for (final c in cast) c.toJson()],
    'directors': directors,
    'writers': writers,
    'tagline': tagline,
    'certification': certification,
    'studios': studios,
    'countries': countries,
    'released': released,
    'videos': [for (final v in videos) v.toJson()],
  };
}

class SignedInDevice {
  const SignedInDevice({
    required this.id,
    required this.name,
    required this.signedInAt,
    required this.lastSeen,
    required this.current,
  });

  final String id;
  final String name;
  final DateTime signedInAt;
  final DateTime lastSeen;

  /// This device.
  final bool current;

  factory SignedInDevice.fromJson(Json j) => SignedInDevice(
    id: j['id'] as String,
    name: j['name'] as String,
    signedInAt: DateTime.fromMillisecondsSinceEpoch((j['signed_in_at'] as int) * 1000),
    lastSeen: DateTime.fromMillisecondsSinceEpoch((j['last_seen'] as int) * 1000),
    current: j['current'] as bool,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'signed_in_at': signedInAt.millisecondsSinceEpoch ~/ 1000,
    'last_seen': lastSeen.millisecondsSinceEpoch ~/ 1000,
    'current': current,
  };
}

class Profile {
  const Profile({required this.user, required this.devices});

  final UserInfo user;
  final List<SignedInDevice> devices;

  factory Profile.fromJson(Json j) => Profile(
    user: UserInfo.fromJson(j['user'] as Json),
    devices: [for (final d in j['devices'] as List) SignedInDevice.fromJson(d as Json)],
  );

  Json toJson() => {
    'user': user.toJson(),
    'devices': [for (final d in devices) d.toJson()],
  };
}

class ProfileUpdate {
  const ProfileUpdate({required this.name});

  final String name;

  factory ProfileUpdate.fromJson(Json j) => ProfileUpdate(name: j['name'] as String);

  Json toJson() => {'name': name};
}

class DeviceSignOut {
  const DeviceSignOut({required this.deviceId});

  final String deviceId;

  factory DeviceSignOut.fromJson(Json j) => DeviceSignOut(deviceId: j['device_id'] as String);

  Json toJson() => {'device_id': deviceId};
}

/// What this device plays, for friends to see.
class NowWatching {
  const NowWatching({
    required this.title,
    required this.metaType,
    required this.metaId,
    required this.paused,
    this.episode,
    this.room,
  });

  /// The movie, or the show for an episode.
  final String title;

  /// Such as `S1 E3 · Pilot`.
  final String? episode;
  final String metaType;
  final String metaId;
  final bool paused;

  /// The watch party room code; only handed to people whose request to join
  /// was accepted.
  final String? room;

  factory NowWatching.fromJson(Json j) => NowWatching(
    title: j['title'] as String,
    episode: j['episode'] as String?,
    metaType: j['meta_type'] as String,
    metaId: j['meta_id'] as String,
    paused: j['paused'] as bool,
    room: j['room'] as String?,
  );

  Json toJson() => {
    'title': title,
    'episode': ?episode,
    'meta_type': metaType,
    'meta_id': metaId,
    'paused': paused,
    'room': ?room,
  };

  @override
  bool operator ==(Object other) =>
      other is NowWatching &&
      other.title == title &&
      other.episode == episode &&
      other.metaType == metaType &&
      other.metaId == metaId &&
      other.paused == paused &&
      other.room == room;

  @override
  int get hashCode => Object.hash(title, episode, metaType, metaId, paused, room);
}

class PresenceUpdate {
  const PresenceUpdate({this.watching});

  /// Null when nothing plays, or sharing is turned off.
  final NowWatching? watching;

  factory PresenceUpdate.fromJson(Json j) {
    final w = j['watching'] as Json?;
    return PresenceUpdate(watching: w == null ? null : NowWatching.fromJson(w));
  }

  Json toJson() => {'watching': watching?.toJson()};
}

/// Another user, as everyone sees them.
class Person {
  const Person({required this.id, required this.name, this.photo});

  final String id;
  final String name;

  /// The profile picture's path under the Hub, fetched with the device token.
  final String? photo;

  factory Person.fromJson(Json j) =>
      Person(id: j['id'] as String, name: j['name'] as String, photo: j['photo'] as String?);

  Json toJson() => {'id': id, 'name': name, 'photo': ?photo};
}

/// A new profile picture, base64. The app crops and shrinks it first.
class ProfilePhotoUpload {
  const ProfilePhotoUpload({required this.image});

  final String image;

  factory ProfilePhotoUpload.fromJson(Json j) => ProfilePhotoUpload(image: j['image'] as String);

  Json toJson() => {'image': image};
}

class FriendWatching {
  const FriendWatching({
    required this.title,
    required this.metaType,
    required this.metaId,
    required this.paused,
    required this.inParty,
    required this.since,
    this.episode,
  });

  final String title;
  final String? episode;
  final String metaType;
  final String metaId;
  final bool paused;

  /// In a watch party; the code stays private.
  final bool inParty;
  final DateTime since;

  factory FriendWatching.fromJson(Json j) => FriendWatching(
    title: j['title'] as String,
    episode: j['episode'] as String?,
    metaType: j['meta_type'] as String,
    metaId: j['meta_id'] as String,
    paused: j['paused'] as bool,
    inParty: j['in_party'] as bool,
    since: DateTime.fromMillisecondsSinceEpoch((j['since'] as int) * 1000),
  );

  Json toJson() => {
    'title': title,
    'episode': ?episode,
    'meta_type': metaType,
    'meta_id': metaId,
    'paused': paused,
    'in_party': inParty,
    'since': since.millisecondsSinceEpoch ~/ 1000,
  };
}

class FriendActivity {
  const FriendActivity({required this.person, required this.online, required this.lastSeen, this.watching});

  final Person person;

  /// The app was open in the last minute and a half.
  final bool online;
  final DateTime lastSeen;
  final FriendWatching? watching;

  factory FriendActivity.fromJson(Json j) {
    final w = j['watching'] as Json?;
    return FriendActivity(
      person: Person.fromJson(j['person'] as Json),
      online: j['online'] as bool,
      lastSeen: DateTime.fromMillisecondsSinceEpoch((j['last_seen'] as int) * 1000),
      watching: w == null ? null : FriendWatching.fromJson(w),
    );
  }

  Json toJson() => {
    'person': person.toJson(),
    'online': online,
    'last_seen': lastSeen.millisecondsSinceEpoch ~/ 1000,
    'watching': watching?.toJson(),
  };
}

/// A request to join someone's watch.
class JoinRequest {
  const JoinRequest({
    required this.id,
    required this.incoming,
    required this.person,
    required this.title,
    required this.status,
    required this.createdAt,
    this.room,
  });

  final String id;

  /// Someone asks to join this user; false for this user's own requests.
  final bool incoming;

  /// Who asked (incoming), or who was asked (outgoing).
  final Person person;
  final String title;

  /// `pending`, `accepted` or `declined`.
  final String status;

  /// The room to join, on an accepted outgoing request.
  final String? room;
  final DateTime createdAt;

  bool get pending => status == 'pending';
  bool get accepted => status == 'accepted';
  bool get declined => status == 'declined';

  factory JoinRequest.fromJson(Json j) => JoinRequest(
    id: j['id'] as String,
    incoming: j['incoming'] as bool,
    person: Person.fromJson(j['person'] as Json),
    title: j['title'] as String,
    status: j['status'] as String,
    room: j['room'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch((j['created_at'] as int) * 1000),
  );

  Json toJson() => {
    'id': id,
    'incoming': incoming,
    'person': person.toJson(),
    'title': title,
    'status': status,
    'room': ?room,
    'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
  };
}

/// Everyone else on the Hub, and this user's join requests.
class Activity {
  const Activity({required this.friends, required this.requests});

  static const empty = Activity(friends: [], requests: []);

  /// Watching first, then online, then by name.
  final List<FriendActivity> friends;
  final List<JoinRequest> requests;

  factory Activity.fromJson(Json j) => Activity(
    friends: [for (final f in j['friends'] as List) FriendActivity.fromJson(f as Json)],
    requests: [for (final r in j['requests'] as List) JoinRequest.fromJson(r as Json)],
  );

  Json toJson() => {
    'friends': [for (final f in friends) f.toJson()],
    'requests': [for (final r in requests) r.toJson()],
  };
}

class JoinRequestCreate {
  const JoinRequestCreate({required this.toUserId});

  final String toUserId;

  factory JoinRequestCreate.fromJson(Json j) => JoinRequestCreate(toUserId: j['to_user_id'] as String);

  Json toJson() => {'to_user_id': toUserId};
}

class JoinRequestAnswer {
  const JoinRequestAnswer({required this.id, required this.accept, this.room});

  final String id;
  final bool accept;

  /// The room to let them in to; the Hub falls back on this user's presence.
  final String? room;

  factory JoinRequestAnswer.fromJson(Json j) =>
      JoinRequestAnswer(id: j['id'] as String, accept: j['accept'] as bool, room: j['room'] as String?);

  Json toJson() => {'id': id, 'accept': accept, 'room': ?room};
}

class JoinRequestCancel {
  const JoinRequestCancel({required this.id});

  final String id;

  factory JoinRequestCancel.fromJson(Json j) => JoinRequestCancel(id: j['id'] as String);

  Json toJson() => {'id': id};
}

/// One chat message. Channels are `public` or a private chat
/// `dm:<user id>:<user id>`, ids sorted (see [directChannel]).
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.channel,
    required this.from,
    required this.text,
    required this.sentAt,
  });

  /// Grows with every message on the Hub: orders and pages them.
  final int id;
  final String channel;
  final Person from;
  final String text;

  /// Unix seconds.
  final int sentAt;

  factory ChatMessage.fromJson(Json j) => ChatMessage(
    id: (j['id'] as num).toInt(),
    channel: j['channel'] as String,
    from: Person.fromJson(j['from'] as Json),
    text: j['text'] as String,
    sentAt: (j['sent_at'] as num).toInt(),
  );

  Json toJson() => {'id': id, 'channel': channel, 'from': from.toJson(), 'text': text, 'sent_at': sentAt};
}

/// A channel this user can read: the public one, or a private chat.
class ChatChannel {
  const ChatChannel({required this.id, this.person, this.last, required this.unread});

  final String id;

  /// The other person, for a private chat.
  final Person? person;
  final ChatMessage? last;

  /// Messages from others after this user's read marker (counted up to 100).
  final int unread;

  bool get isPublic => id == publicChannel;

  ChatChannel copyWith({ChatMessage? last, int? unread}) =>
      ChatChannel(id: id, person: person, last: last ?? this.last, unread: unread ?? this.unread);

  factory ChatChannel.fromJson(Json j) => ChatChannel(
    id: j['id'] as String,
    person: j['person'] == null ? null : Person.fromJson(j['person'] as Json),
    last: j['last'] == null ? null : ChatMessage.fromJson(j['last'] as Json),
    unread: (j['unread'] as num).toInt(),
  );

  Json toJson() => {'id': id, 'person': ?person?.toJson(), 'last': ?last?.toJson(), 'unread': unread};
}

/// The public channel first, then private chats, latest message first.
class ChatOverview {
  const ChatOverview({required this.channels});

  final List<ChatChannel> channels;

  factory ChatOverview.fromJson(Json j) =>
      ChatOverview(channels: [for (final c in j['channels'] as List) ChatChannel.fromJson(c as Json)]);

  Json toJson() => {
    'channels': [for (final c in channels) c.toJson()],
  };
}

/// A page of one channel, oldest first.
class ChatMessages {
  const ChatMessages({required this.messages, required this.more});

  final List<ChatMessage> messages;

  /// There are older (or, when asked for what's `after`, newer) messages.
  final bool more;

  factory ChatMessages.fromJson(Json j) => ChatMessages(
    messages: [for (final m in j['messages'] as List) ChatMessage.fromJson(m as Json)],
    more: j['more'] as bool,
  );

  Json toJson() => {
    'messages': [for (final m in messages) m.toJson()],
    'more': more,
  };
}

/// Sends [text] to [channel]: `public`, `dm:<user id>` or a full private chat id.
class ChatSend {
  const ChatSend({required this.channel, required this.text});

  final String channel;
  final String text;

  factory ChatSend.fromJson(Json j) => ChatSend(channel: j['channel'] as String, text: j['text'] as String);

  Json toJson() => {'channel': channel, 'text': text};
}

/// Marks [channel] read up to and including message [upTo].
class ChatRead {
  const ChatRead({required this.channel, required this.upTo});

  final String channel;
  final int upTo;

  factory ChatRead.fromJson(Json j) => ChatRead(channel: j['channel'] as String, upTo: (j['up_to'] as num).toInt());

  Json toJson() => {'channel': channel, 'up_to': upTo};
}

/// A frame on the live chat socket. Kinds other than `message` are ignored.
class ChatEvent {
  const ChatEvent({required this.kind, this.message});

  final String kind;
  final ChatMessage? message;

  factory ChatEvent.fromJson(Json j) => ChatEvent(
    kind: j['kind'] as String,
    message: j['message'] == null ? null : ChatMessage.fromJson(j['message'] as Json),
  );

  Json toJson() => {'kind': kind, 'message': ?message?.toJson()};
}

/// One track of a video file, shared through the Hub.
class FileTrack {
  const FileTrack({
    required this.kind,
    required this.index,
    this.codec,
    this.language,
    this.name,
    this.channels,
    this.width,
    this.height,
    this.isDefault = false,
    this.isForced = false,
  });

  /// `video`, `audio` or `subtitle`.
  final String kind;
  final int index;
  final String? codec;
  final String? language;
  final String? name;
  final int? channels;
  final int? width;
  final int? height;
  final bool isDefault;
  final bool isForced;

  factory FileTrack.fromJson(Json j) => FileTrack(
    kind: j['kind'] as String,
    index: j['index'] as int,
    codec: j['codec'] as String?,
    language: j['language'] as String?,
    name: j['name'] as String?,
    channels: j['channels'] as int?,
    width: j['width'] as int?,
    height: j['height'] as int?,
    isDefault: j['default'] as bool? ?? false,
    isForced: j['forced'] as bool? ?? false,
  );

  Json toJson() => {
    'kind': kind,
    'index': index,
    'codec': ?codec,
    'language': ?language,
    'name': ?name,
    'channels': ?channels,
    'width': ?width,
    'height': ?height,
    'default': isDefault,
    'forced': isForced,
  };
}

/// A file's tracks from the Hub; [tracks] is null when nobody read it yet.
class FileTracks {
  const FileTracks({this.tracks});

  final List<FileTrack>? tracks;

  factory FileTracks.fromJson(Json j) => FileTracks(
    tracks: j['tracks'] is List ? [for (final t in j['tracks'] as List) FileTrack.fromJson(t as Json)] : null,
  );

  Json toJson() => {'tracks': tracks?.map((t) => t.toJson()).toList()};
}

class FileTracksUpload {
  const FileTracksUpload({required this.key, required this.tracks});

  final String key;
  final List<FileTrack> tracks;

  factory FileTracksUpload.fromJson(Json j) => FileTracksUpload(
    key: j['key'] as String,
    tracks: [for (final t in j['tracks'] as List) FileTrack.fromJson(t as Json)],
  );

  Json toJson() => {'key': key, 'tracks': tracks.map((t) => t.toJson()).toList()};
}
