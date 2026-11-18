# KSPlayer GPL source package

Source: https://github.com/kingslay/KSPlayer/tree/be7f60d3b94a0941c643fe8699113cfce4f08e83
License: GPLv3; see LICENSE.

This is the upstream GPLv3 source snapshot used by Vesper. The later 5.6.2
binary package lacks an iPhone device slice. Sources are retained locally to
allow upgrading FFmpegKit: the upstream manifest restricts it to 6.1.x.

Local manifest changes: pin FFmpegKit to 9.0.2 and omit the test target (upstream
test fixtures are not included). Runtime compatibility patches for FFmpegKit 9.0.2:
- Use typed SwsContext pointers and SwsFlags raw values.
- Let avcodec_free_context close codecs; avcodec_close was removed.
- Discover closed captions from decoded A53 frame side data rather than the
  removed AVCodecContext.properties field.
- Explicitly type the optional pixel-buffer autoreleasepool return value.
