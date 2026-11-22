# App Core

`couchmates_core`: the app's logic, without widgets. The App UI (`../ui`) draws what this package holds.

| Folder | What's in it |
|---|---|
| `lib/src/hub` | `HubClient` and the API shapes (mirroring `core/src/api.rs` at the repo root) |
| `lib/src/session` | `HubSession`: the signed-in user, their config, catalog, trackers, profile and credits |
| `lib/src/stremio` | `StremioClient` for the Telegram-Stremio addon, its models, and stream details parsing |
| `lib/src/library` | Home rows and catalog paging, watch progress (resume, watched marks), My list |
| `lib/src/settings` | `AppSettings` and track choice by preferred language |
| `lib/src/watch` | `WatchRoom` (Open Watch Party), the resolver that finds your copy of the room's title, `Scrobbler` |
| `lib/src/voice` | `VoiceChat` and the LiveKit `VoiceSession`: mic, per-person volume, mic level |

State that's kept on the device (settings, progress, My list) goes through a `SettingsStore`; the app backs it with
its preferences file, and tests use `MemorySettingsStore`.

```bash
export PATH=/c/dev/flutter-3.47.1/bin:$PATH
flutter analyze && flutter test   # includes the shared contract samples in ../../core/contract
```
