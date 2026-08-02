# Third-party notices

Eddy's released application quantizes and writes palette PNGs with its own
built-in Swift encoder (backed by Apple's Compression framework) and does not
link the vendored `libimagequant` sources. The historical sources remain under
`Vendor/libimagequant` with their original license in
[`Vendor/libimagequant/COPYRIGHT`](Vendor/libimagequant/COPYRIGHT), but they are
not part of the app or its release artifacts.

The complete corresponding source for Eddy and its vendored dependencies is
available in this repository. Release artifacts are published from the exact
source commit recorded by the release tag.
