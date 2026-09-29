# Lyric Helper integration: v2 investigation

No changes or deployments were made to Lyric Helper for the desktop bounce release.

The existing `ehynds2077/lyrichelper` app is a Next.js 16 static export, with
passkey sign-in and Jazz groups/file streams for synced private data. Its current
`schema.ts` already models songs with audio files and timestamped comments.
`lib/storage.ts` implements song creation, scoped ownership, and audio upload;
`app/JazzClientProvider.tsx` connects authenticated accounts to the Jazz sync peer.
The audio workspace already offers mobile playback, seeking, markers, and downloads.

A conventional Next POST route will not run in the deployed static export. Add
a separately deployed authenticated service (or move the app to a runtime that
supports API routes), backed by a narrowly scoped Jazz service account. Pair Solo
Studio from the signed-in website and grant that service access only to the
chosen song/workspace. Do not ask the desktop app to copy the user's passkey or
Jazz account secret. Store a revocable device token in macOS Keychain.

Proposed endpoints:

| Endpoint | Purpose |
| --- | --- |
| `POST /api/desktop/pair` | Start an expiring browser-approved device pairing |
| `POST /api/songs` | Create a private song in an explicitly authorized workspace |
| `POST /api/songs/:songId/mix-versions` | Create/version an upload intent with an idempotency key |
| `PUT /api/uploads/:uploadId/full` | Upload the full mix with a bounded size/checksum |
| `PUT /api/uploads/:uploadId/instrumental` | Upload its matching instrumental |
| `POST /api/uploads/:uploadId/complete` | Attach both variants once verified; return the song URL |
| `DELETE /api/desktop/devices/:id` | Revoke a paired Mac |

Authorize every operation against the device's user and selected destination.
Handle interrupted uploads and repeated requests without creating duplicate songs
or half-published pairs. Enforce quotas before accepting bytes, and preserve
private group ownership when creating FileStreams. The existing per-song limit
is 20 audio files, so a version collection or a deliberate quota change is needed
before ten paired bounces fill the song. The `bounce.json` version ID can serve
as the desktop idempotency key; the two M4As, title, notes, timestamp, and range
are sufficient upload inputs. Keep RPP snapshots and raw recordings local by default.

The desktop can then offer **Send to Lyric Helper** and remember the linked song.
The phone uses the existing sign-in and displays paired versions newest-first.
Offline downloads, lock-screen controls, pairing revocation, and completion across
two real devices should be verified before describing it as the phone companion.
