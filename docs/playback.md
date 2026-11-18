# Playback integration

Vesper uses the official KSPlayer GPL source snapshot associated with **5.6.2**,
fixed to commit `be7f60d3b94a0941c643fe8699113cfce4f08e83`, and FFmpegKit
**6.1.4**, fixed to `c32be9bfb628042737ad3ef622e930c5c7b15954`. Both are pinned in
the Xcode project and Package.resolved. The 5.6.2 binary XCFramework has no iPhone
device slice, so Vesper uses its official source snapshot, which supports iPhone.
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
scene(_:openURLContexts:) events. AppDelegate launch/open callbacks, scene/app
user activities containing file URLs, and SwiftUI onOpenURL forwarding all feed
FileDeliveryRouter and then IncomingVideoReceiver.shared. The SwiftUI App observes
that same receiver, so early files remain queued until the UI is ready. Overlapping
cross-callback deliveries of the same file within two seconds are merged; a later
intentional event from the same callback can still reopen the preview.
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
- Save File copies into Documents, creates the local source without switching the current source and refreshes
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

URL-context counts of zero at launch describe only one input channel. Log launch
option keys and user-activity types/keys as well as native and SwiftUI URL events
before concluding no document was handed over. Only file URLs from these inputs
are accepted; no general URL or text document type is registered. When testing,
record whether Vesper is installed directly or hosted by a container, since a host
can change which system callbacks reach the guest app. No private host APIs are used.

## Official KSMPVPlayer backend (build 310 baseline)

Settings → Playback → Playback engine selects KSPlayer or KSMPVPlayer. The player's More
Settings menu switches the current item while retaining position, rate and pause
state. Queue playback keeps the chosen engine and decoder. KSPlayer remains the
default and continues to own its original PiP path.

The official KSMPVPlayer sources are vendored with compatibility patches for
the KSPlayer source API; see Vesper/Infrastructure/Playback/KSMPVPlayer/UPSTREAM.md for the
exact revision and patch scope. KSMPVPlayer uses the public libmpv OpenGL ES render API through a GLKView host,
matching the pinned FFmpegKit 6.1.4 build. The newer upstream CAMetalLayer /
gpu-next / MoltenVK window path is not used. Official MPVPlayer 5.6.2 cannot be linked directly on iPhone because its
KSPlayer XCFramework has no iPhone device slice. MPV's official backend has no
PiP implementation; the app reports that limitation rather than switching engines.

Device checks: MP4/MKV playback, hardware/software decode, seeking while paused,
rate, volume, audio/subtitle selection, next/retry, background audio, returning
to foreground, and switching engines with position restoration.

The Local Video header import action requests a document picker owned by
AppNavigationView, above the tab/navigation content. The picker is not presented
from the page subtree whose header actions are lifted into the navigation overlay.
Selected-file access stays retained until both document delivery and picker
dismissal finish, then the existing import validation/preview flow takes over.
