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
  the KSPlayer source API. Supply a CAMetalLayer host because MetalView is internal; keep upstream
  gpu-next/Vulkan/MoltenVK rendering, rather than Vesper's previous OpenGL adapter.
- Serialize event delivery and player access on MainActor; detach wakeup callback
  before destroying the mpv handle. Correct C flag widths and end-file payload.
- Respect hardware/software decode, playback rate/start position, volume 0...1,
  aspect fill, track selection and subtitle disabling.

Upstream configPIP is empty: this backend does not provide picture-in-picture.
Select KSPlayer to use its existing PiP implementation. MPV renders ASS subtitles
with libass. No claim is made that the official backend implements every KSPlayer feature.
