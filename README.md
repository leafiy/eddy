# Eddy

Eddy is a fast, lightweight image compressor built for macOS. Drop in images or folders and Eddy reduces their size while keeping the workflow simple and predictable.

## Highlights

- Drag and drop images or entire folders
- Paste images with `⌘V` or choose files with `⌘O`
- Supports JPEG, PNG, GIF, BMP, WebP, AVIF, TIFF, and HEIC
- Animated GIF and WebP files are compressed and edited in place — frame count, per-frame timing, loops, and transparency are preserved
- Adjustable quality and maximum width
- Preserves aspect ratio and never enlarges smaller images
- Replaces an original only when the compressed result is actually smaller
- Batch progress and clear per-file results
- Compression history (`⌘Y`) — the last 500 successful runs with their savings; drag files out, reveal them in Finder, or re-compress
- English and Simplified Chinese interface

## Quick Share

Eddy can upload a finished image to your own object storage — Amazon S3, Cloudflare R2, or any S3-compatible service such as Alibaba OSS, Tencent COS, or Backblaze B2 — and copy its link, turning compression and sharing into one quick action. The link is either a public link (optionally on your own CDN or custom domain) or an expiring private link for a bucket you keep private.

## Privacy

- Images are processed locally on your Mac
- Storage credentials are saved as plaintext in Eddy's local settings file
- Eddy does not collect your images or account credentials

## System Requirements

macOS 14 or later.
