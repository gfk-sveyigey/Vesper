# Official KSMPVPlayer source integration

Source: https://github.com/kingslay/KSPlayer/tree/3df1658c3b4a94edc9c9927b8fcc2553a68e9e54/Sources/MPVPlayer
License: GPLv3 (the bundled KSPlayer GPL text applies).

The five Swift files originate from the official MPVPlayer target. This is a
source backport, not a dependency on the 5.6.2 binary: that release omits the
iPhone device slice. Vesper now uses the official KSPlayer GPL source snapshot
`be7f60d3b94a0941c643fe8699113cfce4f08e83`, immediately preceding the 5.6.2
binary packaging change, and FFmpegKit 6.1.4.
MPVCommand, MPVOption and MPVProperty are unmodified upstream files.

Compatibility changes in KSMPVPlayer / MPVHandle:
- Adapt init/replace/shutdown, fileSize, track rotation and subtitle protocol to
  the KSPlayer source API.
- Replace the newer CAMetalLayer/gpu-next/MoltenVK window path with the public
  libmpv OpenGL ES render API supported by FFmpegKit 6.1.4's mpv 0.37 build.
  KSMPVPlayer remains the player implementation; this is a rendering backport,
  not the unmodified upstream renderer or a separate VesperMPVPlayer backend.
- Poll events and render updates on MainActor. Stop display/event timers and
  release the render context with its EAGLContext current before destroying mpv.
- Correct C flag widths and end-file error payloads; report initialization stage
  and mpv error details. Complete seeks on playback restart rather than command
  submission, with a timeout for failed seeks.
- Respect hardware/software decode, playback rate/start position, volume 0...1,
  aspect fill, track selection and subtitle disabling. Pause video rendering in
  the background and restore the video track on foregrounding.

Upstream configPIP is empty: this backend does not provide picture-in-picture.
Select KSPlayer to use its existing PiP implementation. MPV renders ASS subtitles
with libass. No claim is made that the official backend implements every KSPlayer feature.
