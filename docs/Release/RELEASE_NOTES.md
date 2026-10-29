# Drager 0.1.0 (MVP pilot)

## New
- **Throw files from iPhone to Mac.** Pick photos or files, flick them toward the edge facing your Mac, and watch them arrive.
- **Secure pairing.** Compare a 6-digit code once. After that, every connection is encrypted and both devices are verified.
- **Menu bar companion.** Shows status, paired iPhones, the destination folder, recent transfers and an Available switch.
- **Arrival animation.** A card lands on the Mac edge you calibrated. It never takes focus, works over full-screen apps, and shows a static card with Reduce Motion.
- **Reliable saving.** Files are verified with SHA-256 before saving, names never overwrite ("Photo 2.jpeg"), and success is shown only after the file is safely on disk.
- **Recovery.** Automatic reconnection, automatic and manual retry without duplicate files, and clear error messages with fixes.

## Requirements
iOS 26 or later, macOS 26 or later, both devices on the same local network.

## Known limitations
See `docs/KNOWN_LIMITATIONS.md`: 100 MiB per file, foreground sending on iPhone, no resume, one file at a time.
