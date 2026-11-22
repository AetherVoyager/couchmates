/// App Core: the Couchmates app's logic without any UI.
///
/// - Hub: [HubClient] and the app API shapes, which mirror the shared Core
///   crate (`core/src/api.rs`). The tests read the same samples in
///   `core/contract`, so the two sides can't drift.
/// - Rules: usernames, passwords and voice room names, as the Hub checks them.
/// - Stremio: [StremioClient] for the user's catalog (home rows, details,
///   episodes, streams), as Telegram-Stremio serves it, and [probeStream]
///   to list a file's audio and subtitle tracks before playing it.
///   [fetchOnlineSubtitles] adds subtitles from Stremio's OpenSubtitles addon.
/// - Session: [HubSession], the signed-in user, their config and catalog.
/// - Library: [loadHomeRows] and [CatalogPager] for browsing, and
///   [ProgressStore] for where you stopped.
/// - Settings: [AppSettings], and track choice by preferred language.
/// - Watch: [WatchRoom] over Open Watch Party, finding each person's copy
///   in their own catalog.
/// - Voice: [VoiceChat] for the room, with tokens from the Hub.
/// - Trackers: [Scrobbler] reports what's watched to Trakt or Simkl through
///   the Hub.
/// - Social: [Chat] for the public and private chats. [Presence] shares what this device plays, lists who else is
///   watching what, and handles requests to join. [preparePhoto] readies
///   profile pictures.
library;

export 'src/hub/api.dart';
export 'src/hub/hub_client.dart';
export 'src/library/home_feed.dart';
export 'src/library/progress.dart';
export 'src/library/watchlist.dart';
export 'src/rules.dart';
export 'src/session/hub_session.dart';
export 'src/settings/app_settings.dart';
export 'src/social/chat.dart';
export 'src/social/photo.dart';
export 'src/social/presence.dart';
export 'src/settings/track_choice.dart';
export 'src/stremio/media_probe.dart';
export 'src/stremio/models.dart';
export 'src/stremio/online_subtitles.dart';
export 'src/stremio/stream_details.dart';
export 'src/stremio/stremio_client.dart';
export 'src/voice/voice_chat.dart';
export 'src/voice/voice_session.dart';
export 'src/watch/scrobbler.dart';
export 'src/watch/watch_room.dart';
