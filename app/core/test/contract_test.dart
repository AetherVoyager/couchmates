import 'dart:convert';
import 'dart:io';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared samples in the repo's `core/contract` folder.
dynamic sample(String name) => jsonDecode(File('../../core/contract/$name').readAsStringSync());

void main() {
  group('API shapes match the shared contract', () {
    void roundTrips(String file, Json Function(Json) parseAndBack) {
      test(file, () {
        final json = sample(file) as Json;
        expect(parseAndBack(json), json);
      });
    }

    roundTrips('login_request.json', (j) => LoginRequest.fromJson(j).toJson());
    roundTrips('login_response.json', (j) => LoginResponse.fromJson(j).toJson());
    roundTrips('config_response.json', (j) => AppConfig.fromJson(j).toJson());
    roundTrips('config_response_no_addon.json', (j) => AppConfig.fromJson(j).toJson());
    roundTrips('voice_token_request.json', (j) => VoiceTokenRequest.fromJson(j).toJson());
    roundTrips('voice_token_response.json', (j) => VoiceTokenResponse.fromJson(j).toJson());
    roundTrips('voice_token_response_direct.json', (j) => VoiceTokenResponse.fromJson(j).toJson());
    roundTrips('voice_peers_request.json', (j) => VoicePeersRequest.fromJson(j).toJson());
    roundTrips('voice_peers_request_leaving.json', (j) => VoicePeersRequest.fromJson(j).toJson());
    roundTrips('voice_peers.json', (j) => VoicePeers.fromJson(j).toJson());
    roundTrips('voice_signal_send.json', (j) => VoiceSignalSend.fromJson(j).toJson());
    roundTrips('chat_event_voice.json', (j) => ChatEvent.fromJson(j).toJson());
    roundTrips('password_request.json', (j) => PasswordChangeRequest.fromJson(j).toJson());
    roundTrips('ok_response.json', (j) => OkResponse.fromJson(j).toJson());
    roundTrips('error_response.json', (j) => ErrorResponse.fromJson(j).toJson());
    roundTrips('update_info.json', (j) => UpdateInfo.fromJson(j).toJson());
    roundTrips('update_info_none.json', (j) => UpdateInfo.fromJson(j).toJson());
    roundTrips('update_download_request.json', (j) => UpdateDownloadRequest.fromJson(j).toJson());
    roundTrips('update_download.json', (j) => UpdateDownload.fromJson(j).toJson());
    roundTrips('trackers.json', (j) => TrackersResponse.fromJson(j).toJson());
    roundTrips('tracker_request.json', (j) => TrackerRequest.fromJson(j).toJson());
    roundTrips('tracker_link_start.json', (j) => TrackerLinkStart.fromJson(j).toJson());
    roundTrips('tracker_link_poll.json', (j) => TrackerLinkPoll.fromJson(j).toJson());
    roundTrips('scrobble_episode.json', (j) => ScrobbleRequest.fromJson(j).toJson());
    roundTrips('scrobble_movie.json', (j) => ScrobbleRequest.fromJson(j).toJson());
    roundTrips('scrobble_season_watched.json', (j) => ScrobbleRequest.fromJson(j).toJson());
    roundTrips('credits.json', (j) => Credits.fromJson(j).toJson());
    roundTrips('credits_none.json', (j) => Credits.fromJson(j).toJson());
    roundTrips('profile.json', (j) => Profile.fromJson(j).toJson());
    roundTrips('profile_update.json', (j) => ProfileUpdate.fromJson(j).toJson());
    roundTrips('device_sign_out.json', (j) => DeviceSignOut.fromJson(j).toJson());
    roundTrips('profile_photo_upload.json', (j) => ProfilePhotoUpload.fromJson(j).toJson());
    roundTrips('presence_update.json', (j) => PresenceUpdate.fromJson(j).toJson());
    roundTrips('presence_update_idle.json', (j) => PresenceUpdate.fromJson(j).toJson());
    roundTrips('presence_update_private.json', (j) => PresenceUpdate.fromJson(j).toJson());
    roundTrips('presence_update_leaving.json', (j) => PresenceUpdate.fromJson(j).toJson());
    roundTrips('activity.json', (j) => Activity.fromJson(j).toJson());
    roundTrips('join_request_create.json', (j) => JoinRequestCreate.fromJson(j).toJson());
    roundTrips('join_request_answer.json', (j) => JoinRequestAnswer.fromJson(j).toJson());
    roundTrips('join_request_cancel.json', (j) => JoinRequestCancel.fromJson(j).toJson());
    roundTrips('file_tracks.json', (j) => FileTracks.fromJson(j).toJson());
    roundTrips('file_tracks_none.json', (j) => FileTracks.fromJson(j).toJson());
    roundTrips('file_tracks_upload.json', (j) => FileTracksUpload.fromJson(j).toJson());
    roundTrips('chat_overview.json', (j) => ChatOverview.fromJson(j).toJson());
    roundTrips('chat_messages.json', (j) => ChatMessages.fromJson(j).toJson());
    roundTrips('chat_send.json', (j) => ChatSend.fromJson(j).toJson());
    roundTrips('chat_message.json', (j) => ChatMessage.fromJson(j).toJson());
    roundTrips('chat_read.json', (j) => ChatRead.fromJson(j).toJson());
    roundTrips('chat_event.json', (j) => ChatEvent.fromJson(j).toJson());
    roundTrips('chat_event_deleted.json', (j) => ChatEvent.fromJson(j).toJson());
    roundTrips('chat_overview_moderator.json', (j) => ChatOverview.fromJson(j).toJson());
    roundTrips('chat_delete.json', (j) => ChatDelete.fromJson(j).toJson());
    roundTrips('chat_mute.json', (j) => ChatMute.fromJson(j).toJson());
    roundTrips('chat_mute_forever.json', (j) => ChatMute.fromJson(j).toJson());
    roundTrips('media_requests.json', (j) => MediaRequests.fromJson(j).toJson());
    roundTrips('media_request.json', (j) => MediaRequest.fromJson(j).toJson());
    roundTrips('media_request_create.json', (j) => MediaRequestCreate.fromJson(j).toJson());
    roundTrips('media_request_cancel.json', (j) => MediaRequestCancel.fromJson(j).toJson());
    roundTrips('media_request_episode.json', (j) => MediaRequest.fromJson(j).toJson());
    roundTrips('media_request_create_episode.json', (j) => MediaRequestCreate.fromJson(j).toJson());
    roundTrips('media_request_episodes.json', (j) => MediaRequestEpisodes.fromJson(j).toJson());
    roundTrips('subtitle_search_request.json', (j) => SubtitleSearchRequest.fromJson(j).toJson());
    roundTrips('subtitle_search.json', (j) => SubtitleSearch.fromJson(j).toJson());
    roundTrips('subtitle_search_none.json', (j) => SubtitleSearch.fromJson(j).toJson());
    roundTrips('subtitle_download_request.json', (j) => SubtitleDownloadRequest.fromJson(j).toJson());
    roundTrips('subtitle_download.json', (j) => SubtitleDownload.fromJson(j).toJson());
  });

  group('rules match the shared contract', () {
    final cases = sample('rules.json') as Json;

    test('usernames', () {
      for (final c in cases['usernames'] as List) {
        expect(normalizeUsername(c['input'] as String), c['expect'], reason: c['input'] as String);
      }
    });

    test('passwords', () {
      for (final c in cases['passwords'] as List) {
        expect(passwordProblem(c['input'] as String) == null, c['ok'], reason: c['input'] as String);
      }
    });

    test('direct channels', () {
      for (final c in cases['direct_channels'] as List) {
        expect(directChannel(c['a'] as String, c['b'] as String), c['expect']);
      }
    });

    test('chat texts', () {
      for (final c in cases['chat_texts'] as List) {
        final input = (c['input'] as String) * ((c['repeat'] as int?) ?? 1);
        final got = chatText(input);
        expect(got != null, c['ok'], reason: input);
        if (c['expect'] != null) expect(got, c['expect']);
      }
    });

    test('voice rooms', () {
      for (final c in cases['voice_rooms'] as List) {
        expect(roomForWatchCode(c['input'] as String), c['expect'], reason: c['input'] as String);
      }
    });
  });
}
