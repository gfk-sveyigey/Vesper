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

## Receiving videos from other apps

Vesper registers only video document types (public.movie, AVI, MKV and WebM).
UIApplicationDelegateAdaptor configures VesperFileSceneDelegate using the public
SwiftUI integration documented by Apple. SwiftUI still owns all windows and views.
The scene delegate forwards cold-start connectionOptions.urlContexts and warm
scene(_:openURLContexts:) events into IncomingVideoReceiver.shared. The SwiftUI
App observes that same instance, so early files remain queued until the UI is ready.
There is one delivery path; a second SwiftUI onOpenURL handler cannot duplicate it.
The receiver acquires security scope immediately and retains pending files. The actor checks actual readability first; unreadable URLs are silently
ignored. Readable files must have a video type and an actual FFmpeg video stream
(audio-only or renamed text files are rejected with an alert).

Validated files appear in a sheet using CustomPresentationDetent, with filename,
thumbnail and available duration, dimensions and size. System thumbnail extraction
falls back to the existing GPL decoder for unsupported containers. Missing metadata
or thumbnail does not prevent the user choosing an action.

- Direct Play retains the original file's security access in PlaybackSession. It
  does not add a source or copy the video into Documents. Dismissing the sheet/player
  does not release a file that is still playing; Stop or replacement releases it.
- Save File copies into Documents, creates/selects the local source and refreshes
  the media list. Existing filenames receive numeric suffixes. External originals
  are preserved. Opening a file already at the Documents root does not duplicate it.
- Dismiss releases the preview's access without saving or changing playback.

Copies and FFmpeg probing run outside the main actor. File-provider reads/copies
are coordinated, and temporary staging files do not appear in the media list.
VideoImport logs identify app startup/build, scene configuration/connection, native
URL delivery, receiver URL receipt, unreadable rejection, invalid video and
successful validation without logging the full external path.

This uses the system document-opening flow, not a separate Share Extension.
The exact action name/visibility depends on the sending app. Verify on iOS 26:

1. Receive a local MP4 with Vesper stopped, then repeat with it already open.
2. Receive MKV/WebM, portrait and metadata-less videos; preview fallback is allowed.
3. Deliver an unreadable URL: no sheet, alert, source or playback changes.
4. Deliver readable text, empty files, and text/images/audio renamed to .mp4: alert only.
5. Dismiss a preview: no local copy or source creation.
6. Direct Play, minimize and reopen: video continues, library stays unchanged.
7. Save a video twice: both copies remain; save a Documents video: no duplicate.
8. Receive another video while playing or while a preview is open: previews queue
   without overlapping sheet/full-screen transitions.
9. Test iCloud/provider access, a file deleted after inspection and a failed save.

### Native file-delivery entry points

Apple documents the custom scene delegate approach for SwiftUI here:
https://developer.apple.com/documentation/swiftui/uiapplicationdelegateadaptor
Cold-start file contexts are available in scene connection options:
https://developer.apple.com/documentation/uikit/uiscenedelegate/scene(_:willconnectto:options:)
Warm file contexts arrive via:
https://developer.apple.com/documentation/uikit/uiscenedelegate/scene(_:openurlcontexts:)

When diagnosing a failed receipt, distinguish app/scene startup from a nonempty
URL event and receiver validation. An app opening alone does not confirm file
handoff. Confirm actual receipt on device for both a terminated app and an already
running app, as well as delivery while a player/preview is presented. Build success
checks compilation, not the Files app's runtime delivery.

Runtime log loading accepts ISO-8601 timestamps both with and without fractional
seconds. Playback and import callers write whole-second timestamps; silently
dropping those on restart previously made URL-delivery diagnosis unreliable.
Confirm that VideoImport entries survive terminating and reopening Vesper.
