# Playback integration

Vesper uses KSPlayer **2.3.4 (GPLv3)**, fixed to commit
`bdfa2da39bb18865b317c4ffd08cdef5f8efc043`, and FFmpegKit **6.1.4**, fixed
to `c32be9bfb628042737ad3ef622e930c5c7b15954`. Both are pinned in the Xcode
project and Package.resolved. This source release supports iPhone devices;
the newer KSPlayer 5.6.2 GPL binary package has no iPhone device slice.
Upstream: https://github.com/kingslay/KSPlayer and https://github.com/kingslay/FFmpegKit.
The KSPlayer GPL text and playback notices are bundled in the app and available
under Settings → Open-source licenses.

## Ownership

AppNavigationView owns one PlaybackSession. Media cards, the native TabView
bottom accessory and PlayerScreen all use that session. Closing the full-screen
player only dismisses its UI; Stop tears down playback and releases file access.
Changing tabs or selecting another source does not replace the current session.
KSPlayer uses its AVPlayer backend first and FFmpeg backend as fallback.
No navigation hosts, touch bridges or custom tab event handling are introduced.

Local videos resolve from the same Documents folder (or legacy security-scoped
bookmark) used for browsing. Access stays open until the player is stopped or
another video replaces it. Photos full-size video resources are materialized in
a unique temporary file, downloading from iCloud if needed. This plays the
full-size/original video resource, rather than rendering Photos nondestructive
edits. Downloads display a loading state; stale or cancelled results never
replace a later selection, and temporary files are removed when released.
Photos' writeData API cannot cancel an in-flight download; a cancelled request's
file is removed when its completion arrives.

## Initial scope and validation

Includes play/pause, seek, ±15 seconds, next in the current source's queue,
retry, stop and playback error logs. Selecting another video replaces the
previous one. Reaching the end pauses for replay or manual Next. Background
audio entitlement, picture-in-picture, subtitle selection, history persistence,
Emby and playback preferences are separate follow-up features.

CI must compile the generic iOS device target with Xcode 26. Runtime checks:

1. Add Local Video, put MP4 and MKV files in Vesper's Files folder, refresh and play.
2. Play a local/iCloud Photos video, deny/revoke Photos access and check errors.
3. Pause, seek while paused, resume, reach end, replay, next and stop.
4. Minimize, switch tabs and reopen: position and decoder must stay alive.
5. Rapidly select videos while Photos downloads: only the latest may play.
6. Try a missing/corrupt file; retry or switch video without freezing navigation.
7. Toggle mini-player enabled/always-visible and minimize the tab bar.

## Importing videos from other apps

Vesper registers as an alternate video document viewer. In Files or another app
that supports Open In, choose Vesper to import MP4, MOV, M4V, MKV, AVI or WebM.
The app copies the video into Documents, creates/selects the Local Video source,
and refreshes the media list without starting playback. Existing filenames get
numeric suffixes; opening a video already at the root of Documents does not
create a duplicate. External originals are left intact. Only private Inbox
copies are removed after successful import. File-provider reads are coordinated,
security-scoped access covers the entire copy, and staging files are never
published to the media list before completion. Large copies run off the UI thread.

This uses the system document-opening flow, not a separate Share Extension.
The exact action name/visibility depends on the sending app. Verify both cold
and warm launch, an iCloud file, duplicate names, an unsupported file, import
while another video is playing, and a Files URL already inside Documents.
