//! The app API (`/api/app/*`). Signed-in calls send
//! `Authorization: Bearer <token>` with the token from [`LoginResponse`].
//! Failures answer with a 4xx/5xx status and an [`ErrorResponse`].
//!
//! | Call | Request | Response |
//! |---|---|---|
//! | `POST /api/app/login` | [`LoginRequest`] | [`LoginResponse`] |
//! | `GET /api/app/config` | | [`AppConfig`] |
//! | `POST /api/app/voice-token` | [`VoiceTokenRequest`] | [`VoiceTokenResponse`] |
//! | `POST /api/app/password` | [`PasswordChangeRequest`] | [`OkResponse`] |
//! | `POST /api/app/logout` | | [`OkResponse`] |
//! | `GET /api/app/update?platform=windows&version=0.1.0` | | [`UpdateInfo`] |
//! | `POST /api/app/update/download` | [`UpdateDownloadRequest`] | [`UpdateDownload`] |
//! | `GET /api/app/trackers` | | [`TrackersResponse`] |
//! | `POST /api/app/trackers/link` | [`TrackerRequest`] | [`TrackerLinkStart`] |
//! | `POST /api/app/trackers/poll` | [`TrackerRequest`] | [`TrackerLinkPoll`] |
//! | `POST /api/app/trackers/unlink` | [`TrackerRequest`] | [`OkResponse`] |
//! | `POST /api/app/scrobble` | [`ScrobbleRequest`] | [`OkResponse`] |
//! | `GET /api/app/credits?type=movie&tmdb=603&imdb=tt0133093` | | [`Credits`] |
//! | `GET /api/app/profile` | | [`Profile`] |
//! | `POST /api/app/profile` | [`ProfileUpdate`] | [`Profile`] |
//! | `POST /api/app/devices/sign-out` | [`DeviceSignOut`] | [`OkResponse`] |
//! | `POST /api/app/profile/photo` | [`ProfilePhotoUpload`] | [`Profile`] |
//! | `POST /api/app/profile/photo/remove` | | [`Profile`] |
//! | `GET /api/app/photos/{user_id}?v=…` | | the picture (JPEG, PNG or WebP) |
//! | `POST /api/app/presence` | [`PresenceUpdate`] | [`Activity`] |
//! | `POST /api/app/join-requests` | [`JoinRequestCreate`] | [`Activity`] |
//! | `POST /api/app/join-requests/answer` | [`JoinRequestAnswer`] | [`Activity`] |
//! | `POST /api/app/join-requests/cancel` | [`JoinRequestCancel`] | [`Activity`] |
//! | `GET /api/app/tracks?key=…` | | [`FileTracks`] |
//! | `POST /api/app/tracks` | [`FileTracksUpload`] | [`OkResponse`] |
//! | `GET /api/app/chat` | | [`ChatOverview`] |
//! | `GET /api/app/chat/messages?channel=public&before=120&after=80` | | [`ChatMessages`] |
//! | `POST /api/app/chat/send` | [`ChatSend`] | [`ChatMessage`] |
//! | `POST /api/app/chat/read` | [`ChatRead`] | [`OkResponse`] |
//! | `GET /api/app/chat/live` (WebSocket) | | a stream of [`ChatEvent`] text frames |
//! | `GET /api/app/requests` | | [`MediaRequests`] |
//! | `POST /api/app/requests` | [`MediaRequestCreate`] | [`MediaRequest`] |
//! | `POST /api/app/requests/episodes` | [`MediaRequestEpisodes`] | [`MediaRequests`] |
//! | `POST /api/app/requests/cancel` | [`MediaRequestCancel`] | [`OkResponse`] |

use serde::{Deserialize, Serialize};

pub mod paths {
    pub const LOGIN: &str = "/api/app/login";
    pub const CONFIG: &str = "/api/app/config";
    pub const VOICE_TOKEN: &str = "/api/app/voice-token";
    pub const PASSWORD: &str = "/api/app/password";
    pub const LOGOUT: &str = "/api/app/logout";
    pub const UPDATE: &str = "/api/app/update";
    pub const UPDATE_DOWNLOAD: &str = "/api/app/update/download";
    pub const TRACKERS: &str = "/api/app/trackers";
    pub const TRACKERS_LINK: &str = "/api/app/trackers/link";
    pub const TRACKERS_POLL: &str = "/api/app/trackers/poll";
    pub const TRACKERS_UNLINK: &str = "/api/app/trackers/unlink";
    pub const SCROBBLE: &str = "/api/app/scrobble";
    pub const CREDITS: &str = "/api/app/credits";
    pub const PROFILE: &str = "/api/app/profile";
    pub const DEVICE_SIGN_OUT: &str = "/api/app/devices/sign-out";
    pub const PROFILE_PHOTO: &str = "/api/app/profile/photo";
    pub const PROFILE_PHOTO_REMOVE: &str = "/api/app/profile/photo/remove";
    /// Followed by the user id.
    pub const PHOTOS: &str = "/api/app/photos/";
    pub const PRESENCE: &str = "/api/app/presence";
    pub const JOIN_REQUESTS: &str = "/api/app/join-requests";
    pub const JOIN_REQUESTS_ANSWER: &str = "/api/app/join-requests/answer";
    pub const JOIN_REQUESTS_CANCEL: &str = "/api/app/join-requests/cancel";
    pub const TRACKS: &str = "/api/app/tracks";
    pub const CHAT: &str = "/api/app/chat";
    pub const CHAT_MESSAGES: &str = "/api/app/chat/messages";
    pub const CHAT_SEND: &str = "/api/app/chat/send";
    pub const CHAT_READ: &str = "/api/app/chat/read";
    pub const CHAT_LIVE: &str = "/api/app/chat/live";
    pub const REQUESTS: &str = "/api/app/requests";
    pub const REQUESTS_CANCEL: &str = "/api/app/requests/cancel";
    pub const REQUESTS_EPISODES: &str = "/api/app/requests/episodes";
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
    /// Shown to the admin in the user's device list.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LoginResponse {
    /// The device token. Valid until the user signs out or the admin signs
    /// the device out.
    pub token: String,
    pub user: UserInfo,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UserInfo {
    pub id: String,
    pub name: String,
    pub username: Option<String>,
    /// The profile picture: a path under the Hub such as
    /// `/api/app/photos/<user id>?v=<version>`, fetched with the device token.
    /// The version changes with the picture, so it can be cached for good.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub photo: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppConfig {
    pub user: UserInfo,
    pub device: DeviceInfo,
    /// The user's catalog (a Stremio addon). None until the admin connects
    /// Telegram-Stremio.
    pub addon: Option<AddonInfo>,
    /// Public Stremio add-ons the admin turned on, in order. The app asks them
    /// after [`AppConfig::addon`]: their catalogs add home rows, and their
    /// details, streams and subtitles are merged in.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub addons: Vec<ExtraAddon>,
    pub voice: VoiceInfo,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExtraAddon {
    /// The Hub's id for it. Catalog keys in the app start with it.
    pub id: String,
    pub name: String,
    /// `<base_url>/manifest.json`, `/catalog/…` and so on.
    pub base_url: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AddonInfo {
    /// `<base_url>/catalog/…`, `/meta/…` and `/stream/…` follow the Stremio
    /// addon protocol.
    pub base_url: String,
    pub manifest_url: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceInfo {
    pub available: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceTokenRequest {
    /// The watch party room code.
    pub room: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceTokenResponse {
    /// LiveKit server URL (`wss://…`).
    pub url: String,
    /// LiveKit join token, valid for 6 hours, microphone only.
    pub token: String,
    pub room: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PasswordChangeRequest {
    pub current_password: String,
    pub new_password: String,
}

/// Whether a newer app is out, from the newest versioned GitHub release
/// (pre-releases such as "Latest build" don't count).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateInfo {
    /// False when the Hub has no GitHub access set up, or no release has an
    /// installer for this platform.
    pub available: bool,
    /// The newest version, such as `0.2.0`.
    pub latest_version: Option<String>,
    /// True when [`latest_version`](Self::latest_version) is newer than the
    /// version the app sent.
    pub newer: bool,
    /// The release notes, as Markdown.
    pub notes: Option<String>,
    pub size_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateDownloadRequest {
    /// `windows`.
    pub platform: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateDownload {
    /// A short-lived link to the installer; fetch it without any headers.
    pub url: String,
    pub version: String,
    pub file_name: String,
}

/// A tracker service: `trakt` or `simkl`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackerStatus {
    pub service: String,
    /// The admin has set up this service on the Hub.
    pub available: bool,
    pub linked: bool,
    /// The account name on the service, once linked.
    pub username: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackersResponse {
    pub trackers: Vec<TrackerStatus>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackerRequest {
    pub service: String,
}

/// Show [`user_code`](Self::user_code) and ask the user to enter it at
/// [`verification_url`](Self::verification_url), then poll every
/// [`interval`](Self::interval) seconds.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackerLinkStart {
    pub user_code: String,
    pub verification_url: String,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackerLinkPoll {
    /// `pending`, `linked`, `expired` or `denied`.
    pub status: String,
    pub username: Option<String>,
}

/// What's playing, for the linked trackers. Only titles with an IMDb id can
/// be scrobbled.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScrobbleRequest {
    /// `start`, `pause` or `stop`.
    pub action: String,
    /// `movie` or `episode`.
    pub kind: String,
    /// The movie's IMDb id, or the show's for an episode.
    pub imdb: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
    /// Percent watched, 0–100.
    pub progress: f64,
}

/// Who's in a title and who made it, from TMDB when the Hub has a key.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Credits {
    /// False when the Hub has no TMDB key or TMDB doesn't know the title;
    /// the app then falls back on the catalog's names.
    pub available: bool,
    pub cast: Vec<CastMember>,
    pub directors: Vec<String>,
    pub writers: Vec<String>,
    /// A one-line hook, such as "Your mind is the scene of the crime."
    #[serde(default)]
    pub tagline: Option<String>,
    /// The age rating, such as `PG-13` or `TV-MA`.
    #[serde(default)]
    pub certification: Option<String>,
    #[serde(default)]
    pub studios: Vec<String>,
    #[serde(default)]
    pub countries: Vec<String>,
    /// First release (movies) or first air date (shows), `YYYY-MM-DD`.
    #[serde(default)]
    pub released: Option<String>,
    /// Trailers, teasers and featurettes on YouTube.
    #[serde(default)]
    pub videos: Vec<Extra>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Extra {
    pub name: String,
    /// `Trailer`, `Teaser`, `Featurette`, `Clip`…
    pub kind: String,
    /// The YouTube video id.
    pub youtube: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CastMember {
    pub name: String,
    pub character: Option<String>,
    /// A small portrait (TMDB `w185`), when there is one.
    pub photo: Option<String>,
}

/// The signed-in user and every device they're signed in on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Profile {
    pub user: UserInfo,
    pub devices: Vec<SignedInDevice>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SignedInDevice {
    pub id: String,
    pub name: String,
    /// Unix seconds.
    pub signed_in_at: i64,
    pub last_seen: i64,
    /// The device making this request.
    pub current: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileUpdate {
    /// The display name others see, 1–60 characters.
    pub name: String,
}

/// A new profile picture. The app crops and shrinks it first (a 256-pixel
/// square JPEG is about 30 KB); the Hub takes up to 300 KB.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfilePhotoUpload {
    /// The picture's bytes, base64. JPEG, PNG or WebP.
    pub image: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceSignOut {
    pub device_id: String,
}

/// Sent every 20 seconds or so while the app is open, and right away when
/// playback changes. Marks the user online and answers with what everyone
/// else is up to.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PresenceUpdate {
    /// What this device is playing. None when nothing is, or when the user
    /// turned off sharing what they watch.
    pub watching: Option<NowWatching>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NowWatching {
    /// The movie, or the show for an episode.
    pub title: String,
    /// The episode, such as `S1 E3 · Pilot`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<String>,
    /// The catalog type (`movie`, `series`) and id, so friends can look the
    /// title up in their own catalog.
    pub meta_type: String,
    pub meta_id: String,
    pub paused: bool,
    /// The watch party room code this device is in. Only given to people
    /// whose request to join was accepted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
    /// The poster (an https URL), for the admin's Tracearr.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    /// Where playback is and what the file is, for the admin's Tracearr.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playback: Option<PlaybackInfo>,
    /// The user turned off sharing what they watch: friends aren't shown it,
    /// only the admin's Tracearr is.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub private: bool,
}

/// The player's position and the file's format. Only the admin's Tracearr
/// sees these.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PlaybackInfo {
    pub position_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    /// Such as `hevc` or `h264`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_codec: Option<String>,
    /// Such as `eac3` or `aac`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_codec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_channels: Option<u32>,
    /// Video bitrate in bits per second.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate: Option<i64>,
}

/// Another user, as everyone sees them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Person {
    pub id: String,
    pub name: String,
    /// The profile picture: a path under the Hub such as
    /// `/api/app/photos/<user id>?v=<version>`, fetched with the device token.
    /// The version changes with the picture, so it can be cached for good.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub photo: Option<String>,
}

/// Everyone else on the Hub, and the join requests to or from this user.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Activity {
    /// Watching first, then online, then by name. Users who never opened
    /// this version of the app aren't listed.
    pub friends: Vec<FriendActivity>,
    pub requests: Vec<JoinRequest>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FriendActivity {
    pub person: Person,
    /// The app was open in the last minute and a half.
    pub online: bool,
    /// Unix seconds the app was last open.
    pub last_seen: i64,
    pub watching: Option<FriendWatching>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FriendWatching {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<String>,
    pub meta_type: String,
    pub meta_id: String,
    pub paused: bool,
    /// They're in a watch party (the code stays private).
    pub in_party: bool,
    /// Unix seconds they started this title.
    pub since: i64,
}

/// A request to join someone's watch. Pending ones last 2 minutes, answered
/// ones stay listed for 2 minutes after the answer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JoinRequest {
    pub id: String,
    /// True when someone asks to join this user; false for this user's own
    /// requests.
    pub incoming: bool,
    /// Who asked (incoming), or who was asked (outgoing).
    pub person: Person,
    /// What the person asked was watching at the time.
    pub title: String,
    /// `pending`, `accepted` or `declined`.
    pub status: String,
    /// The room to join, on an accepted outgoing request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
    /// Unix seconds.
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JoinRequestCreate {
    /// The user to ask. They must be watching something.
    pub to_user_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JoinRequestAnswer {
    pub id: String,
    pub accept: bool,
    /// The room to let them into. When left out on accept, the room in this
    /// user's presence is used; with neither, the answer is refused.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
}

/// Withdraws an outgoing request, or clears one from the list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JoinRequestCancel {
    pub id: String,
}

/// One track of a video file, as an app read it from the file's start.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileTrack {
    /// `video`, `audio` or `subtitle`.
    pub kind: String,
    /// 1-based position among the tracks of its kind, in file order.
    pub index: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    #[serde(default)]
    pub default: bool,
    #[serde(default)]
    pub forced: bool,
}

/// A file's tracks, shared through the Hub so a file read once by anyone
/// shows its tracks at once for everyone. `tracks` is null when nobody has
/// read the file yet.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileTracks {
    pub tracks: Option<Vec<FileTrack>>,
}

/// Saves a file's tracks. [key] names the file the same way for everyone:
/// see `fileKey` in the app.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileTracksUpload {
    pub key: String,
    pub tracks: Vec<FileTrack>,
}

/// One chat message. Channels are `public` (everyone on the Hub) or a
/// private chat between two people, `dm:<user id>:<user id>` with the ids
/// sorted (see `rules::direct_channel`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    /// Grows with every message on the Hub, so it orders and pages them.
    pub id: i64,
    pub channel: String,
    pub from: Person,
    pub text: String,
    /// Unix seconds.
    pub sent_at: i64,
}

/// A channel this user can read: the public one, or a private chat.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatChannel {
    pub id: String,
    /// The other person, for a private chat.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person: Option<Person>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<ChatMessage>,
    /// Messages from others after this user's read marker.
    pub unread: u32,
}

/// The public channel first, then private chats, latest message first.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatOverview {
    pub channels: Vec<ChatChannel>,
}

/// A page of one channel, oldest first. Without `before` or `after` it's the
/// latest page; `before` pages back, `after` fetches what's newer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatMessages {
    pub messages: Vec<ChatMessage>,
    /// There are older (or, with `after`, newer) messages than this page.
    pub more: bool,
}

/// Sends [text] to [channel]: `public`, or `dm:<user id>` (or the full
/// `dm:<a>:<b>` id) for a private chat with that user.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatSend {
    pub channel: String,
    pub text: String,
}

/// Marks [channel] read up to and including message [up_to].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatRead {
    pub channel: String,
    pub up_to: i64,
}

/// A frame on the live chat socket. `kind` is `message` for now; apps ignore
/// kinds they don't know. A `ping` text frame is answered with `pong`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatEvent {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<ChatMessage>,
}

/// A request's status. Only the admin changes it, on the dashboard's Requests page. Asking never downloads
/// anything: the admin adds the title to Telegram-Stremio by hand.
pub mod request_status {
    /// Waiting for the admin.
    pub const PENDING: &str = "pending";
    /// The admin will add it.
    pub const APPROVED: &str = "approved";
    /// It's in the library now.
    pub const ADDED: &str = "added";
    pub const DECLINED: &str = "declined";
    pub const ALL: &[&str] = &[PENDING, APPROVED, ADDED, DECLINED];
}

/// A title someone asked the admin to add to the library: a movie, one episode of a show (with `season` and
/// `episode`), or a whole show (older apps). There is one per title or episode: friends asking for the same one
/// are listed together in [`MediaRequest::requested_by`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaRequest {
    pub id: String,
    /// `movie` or `series`.
    pub kind: String,
    /// The title's Stremio id, usually its IMDb id (`tt…`).
    pub title_id: String,
    pub name: String,
    /// Free text such as `1999` or `2008–2013`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<String>,
    /// An https poster link from the catalog that found it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    /// For one episode of a show: its season number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    /// For one episode of a show: its number in the season.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
    /// The episode's name, when the catalog knew it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode_title: Option<String>,
    /// One of [`request_status::ALL`].
    pub status: String,
    /// The admin's note to whoever asked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// Display names of who asked, first asker first.
    pub requested_by: Vec<String>,
    /// Whether the signed-in user is among them.
    pub mine: bool,
    pub created_at: i64,
    pub updated_at: i64,
}

/// Every request, most recently changed first.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaRequests {
    pub requests: Vec<MediaRequest>,
}

/// Asks for a title, or adds the user to an existing request for it. A declined title asked for again goes
/// back to pending.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaRequestCreate {
    /// `movie` or `series`.
    pub kind: String,
    pub title_id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    /// With `episode`, asks for one episode of a series.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode_title: Option<String>,
}

/// One episode in a [`MediaRequestEpisodes`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EpisodeAsk {
    pub season: u32,
    pub episode: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

/// Asks for several episodes of one series at once (at most 40), such as a season or the episodes the library
/// is missing. Each episode is its own request; the answer lists them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaRequestEpisodes {
    pub title_id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    pub episodes: Vec<EpisodeAsk>,
}

/// The bot API's answer to a request (`POST /api/bot/requests/update`, see `hub/core/src/bot.rs`). Without
/// `note` the request keeps the one it has; an empty note clears it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaRequestUpdate {
    pub id: String,
    /// One of [`request_status::ALL`].
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// What the Hub POSTs to the bot's webhook. `event` is `request.created` for a new request or a declined one
/// asked for again; bots ignore events they don't know.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BotWebhook {
    pub event: String,
    pub request: MediaRequest,
}

/// What the bot says about itself (`POST /api/bot/status`, see `hub/core/src/bot.rs`), about every 30 seconds.
/// The Overview page shows it. A bot that stops reporting shows as offline.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BotStatus {
    /// `idle`, `working` or `error`.
    pub state: String,
    /// What it is doing, or what went wrong, in a sentence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Things that happened since the last report. The Hub keeps the latest 50.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub events: Vec<BotEvent>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BotEvent {
    /// Unix seconds when it happened.
    pub at: i64,
    /// `info` or `error`.
    pub level: String,
    pub message: String,
}

/// Takes the user's name off a request. A pending request nobody wants any more is removed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaRequestCancel {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OkResponse {
    pub ok: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorResponse {
    /// A sentence the app can show as is.
    pub error: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::de::DeserializeOwned;
    use serde_json::Value;

    /// A contract sample parses as its type and serializes back unchanged.
    fn round_trips<T: DeserializeOwned + Serialize>(sample: &str) {
        let value: Value = serde_json::from_str(sample).unwrap();
        let typed: T = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(&typed).unwrap(), value);
    }

    #[test]
    fn contract_samples_round_trip() {
        round_trips::<LoginRequest>(include_str!("../contract/login_request.json"));
        round_trips::<LoginResponse>(include_str!("../contract/login_response.json"));
        round_trips::<AppConfig>(include_str!("../contract/config_response.json"));
        round_trips::<AppConfig>(include_str!("../contract/config_response_no_addon.json"));
        round_trips::<VoiceTokenRequest>(include_str!("../contract/voice_token_request.json"));
        round_trips::<VoiceTokenResponse>(include_str!("../contract/voice_token_response.json"));
        round_trips::<PasswordChangeRequest>(include_str!("../contract/password_request.json"));
        round_trips::<OkResponse>(include_str!("../contract/ok_response.json"));
        round_trips::<ErrorResponse>(include_str!("../contract/error_response.json"));
        round_trips::<UpdateInfo>(include_str!("../contract/update_info.json"));
        round_trips::<UpdateInfo>(include_str!("../contract/update_info_none.json"));
        round_trips::<UpdateDownloadRequest>(include_str!("../contract/update_download_request.json"));
        round_trips::<UpdateDownload>(include_str!("../contract/update_download.json"));
        round_trips::<TrackersResponse>(include_str!("../contract/trackers.json"));
        round_trips::<TrackerRequest>(include_str!("../contract/tracker_request.json"));
        round_trips::<TrackerLinkStart>(include_str!("../contract/tracker_link_start.json"));
        round_trips::<TrackerLinkPoll>(include_str!("../contract/tracker_link_poll.json"));
        round_trips::<ScrobbleRequest>(include_str!("../contract/scrobble_episode.json"));
        round_trips::<ScrobbleRequest>(include_str!("../contract/scrobble_movie.json"));
        round_trips::<Credits>(include_str!("../contract/credits.json"));
        round_trips::<Credits>(include_str!("../contract/credits_none.json"));
        round_trips::<Profile>(include_str!("../contract/profile.json"));
        round_trips::<ProfileUpdate>(include_str!("../contract/profile_update.json"));
        round_trips::<DeviceSignOut>(include_str!("../contract/device_sign_out.json"));
        round_trips::<ProfilePhotoUpload>(include_str!("../contract/profile_photo_upload.json"));
        round_trips::<PresenceUpdate>(include_str!("../contract/presence_update.json"));
        round_trips::<PresenceUpdate>(include_str!("../contract/presence_update_idle.json"));
        round_trips::<PresenceUpdate>(include_str!("../contract/presence_update_private.json"));
        round_trips::<Activity>(include_str!("../contract/activity.json"));
        round_trips::<JoinRequestCreate>(include_str!("../contract/join_request_create.json"));
        round_trips::<JoinRequestAnswer>(include_str!("../contract/join_request_answer.json"));
        round_trips::<JoinRequestCancel>(include_str!("../contract/join_request_cancel.json"));
        round_trips::<FileTracks>(include_str!("../contract/file_tracks.json"));
        round_trips::<FileTracks>(include_str!("../contract/file_tracks_none.json"));
        round_trips::<FileTracksUpload>(include_str!("../contract/file_tracks_upload.json"));
        round_trips::<ChatOverview>(include_str!("../contract/chat_overview.json"));
        round_trips::<ChatMessages>(include_str!("../contract/chat_messages.json"));
        round_trips::<ChatSend>(include_str!("../contract/chat_send.json"));
        round_trips::<ChatMessage>(include_str!("../contract/chat_message.json"));
        round_trips::<ChatRead>(include_str!("../contract/chat_read.json"));
        round_trips::<ChatEvent>(include_str!("../contract/chat_event.json"));
        round_trips::<MediaRequests>(include_str!("../contract/media_requests.json"));
        round_trips::<MediaRequest>(include_str!("../contract/media_request.json"));
        round_trips::<MediaRequestCreate>(include_str!("../contract/media_request_create.json"));
        round_trips::<MediaRequestCancel>(include_str!("../contract/media_request_cancel.json"));
        round_trips::<MediaRequest>(include_str!("../contract/media_request_episode.json"));
        round_trips::<MediaRequestCreate>(include_str!("../contract/media_request_create_episode.json"));
        round_trips::<MediaRequestEpisodes>(include_str!("../contract/media_request_episodes.json"));
        round_trips::<MediaRequestUpdate>(include_str!("../contract/media_request_update.json"));
        round_trips::<BotWebhook>(include_str!("../contract/bot_webhook.json"));
        round_trips::<BotStatus>(include_str!("../contract/bot_status.json"));
    }
}
