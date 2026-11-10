# IPCC Extractor

[简体中文](README.md) | [English](README.en.md)

A macOS app for finding and exporting carrier bundles from iPhone and cellular iPad firmware.

## What’s new in 1.1 Beta

- Fixed truncated English text in the About window.
- Added a GitHub icon beside the project link.
- The installer replaces the previous version; quit it before updating.

## Download and install

Download the Apple Silicon DMG from [Releases](https://github.com/Today1314/IPCC-Extractor/releases), open it, and drag the app to Applications. Quit any earlier version normally before replacing it. The first public release is **1.0 Beta**.

Requires an Apple Silicon Mac with macOS 14 or later. The app is ad-hoc signed and is not notarized by Apple. If macOS blocks it, check System Settings → Privacy & Security.

## Usage

Select a local IPSW, decrypted disk image, or extracted folder. Confirm firmware details, select carriers, and export. Chinese and English are available inside the app.

AEA-encrypted system images require an internet connection to Apple's key service. Decryption, scanning, and export run locally; the firmware is not uploaded. Normal quit or switching input cleans temporary files created by the app. Do not force-quit while processing.

Exported archives are checked for structure and file content; Apple signatures, device compatibility, and installation are not verified. Some firmware images cannot be accessed directly; see the app's error messages for details.

## Build from source

Install Apple's Command Line Tools and a macOS Python 3.13 framework that supports arm64. Then run:

```sh
PYTHON_FRAMEWORK=/Library/Frameworks/Python.framework bash ./build.sh
```

Set `OUTPUT_DIR` to change the output directory. The build copies the supplied Python framework into the app; retain its license and notices when distributing it. A build produced with this script is ad-hoc signed, not notarized. Apple frameworks and tools, including `aea` and `hdiutil`, are supplied by macOS and are not included in this repository.

## Source and distribution

Source code is published for inspection. No open-source license has been selected yet; please obtain permission from the repository owner before reusing or redistributing the project's code or artwork. The packaged Python runtime remains subject to its own license and notices, which are included in the application bundle. Firmware and carrier bundles are not distributed with this project.
