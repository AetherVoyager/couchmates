# Couchmates Core

`couchmates-core`: what the Hub and the app agree on. No Cloudflare or Flutter code, so it builds and tests
anywhere.

- `src/api.rs`: every app API call's request and response shape. The table at its top lists the calls.
- `src/rules.rs`: usernames, passwords and voice room names, checked the same way on both sides.
- `contract/`: a JSON sample of each shape. The Rust tests here and the Dart tests in `app/core` both read them,
  so the two sides can't drift apart.

## The app API

Signed-in calls send `Authorization: Bearer <device token>`. Failures answer with a 4xx or 5xx status and
`{"error": "<a sentence to show>"}`.

| Call | What it does |
|---|---|
| `POST /api/app/login` | Username and password → device token |
| `GET /api/app/config` | The user, this device, their catalog address, whether voice is set up |
| `POST /api/app/voice-token` | A LiveKit token for a watch party room |
| `POST /api/app/password` | Change password; signs out the user's other devices |
| `POST /api/app/logout` | Sign this device out |
| `GET /api/app/profile`, `POST /api/app/profile` | The user and their devices; change the display name |
| `POST /api/app/devices/sign-out` | Sign out another of the user's devices |
| `POST /api/app/profile/photo{,/remove}`, `GET /api/app/photos/{user_id}` | Set or remove your profile picture; fetch anyone's |
| `GET /api/app/update`, `POST /api/app/update/download` | Newest release, and a short-lived link to its installer |
| `GET /api/app/trackers`, `POST /api/app/trackers/{link,poll,unlink}` | Link Trakt or Simkl with a device code |
| `POST /api/app/scrobble` | Start, pause or stop, forwarded to linked trackers |
| `GET /api/app/credits` | Cast, crew, age rating, tagline, studios and trailers from TMDB |
| `POST /api/app/presence` | Say what's playing (or that the app is open); get who else is watching what |
| `POST /api/app/join-requests{,/answer,/cancel}` | Ask to join someone's watch; accept, decline or withdraw |
| `GET /api/app/requests`, `POST /api/app/requests{,/cancel}` | Titles friends asked the admin to add, with status; ask for one or withdraw |

Adding or changing a call: see "Changing the app API" in `CLAUDE.md`.
