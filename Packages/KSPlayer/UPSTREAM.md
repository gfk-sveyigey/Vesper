# KSPlayer GPL source package

Source: https://github.com/kingslay/KSPlayer/tree/be7f60d3b94a0941c643fe8699113cfce4f08e83
License: GPLv3; see LICENSE.

This is the upstream GPLv3 source snapshot used by Vesper. The later 5.6.2
binary package lacks an iPhone device slice. Sources are retained locally to
allow upgrading FFmpegKit: the upstream manifest restricts it to 6.1.x.

Local manifest changes: pin FFmpegKit to 9.0.2 and omit the test target (upstream
test fixtures are not included). Runtime sources initially match upstream.
