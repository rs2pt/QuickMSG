# QuickMSG

Quick Look preview for Outlook `.msg` files on macOS. Select a `.msg` in Finder, press space, and read the
message without Outlook.

It shows the subject, sender, recipients, date, attachment list and the body: HTML mail looks the way
Outlook stored it, including inline images. Remote content is blocked, so tracking pixels are never loaded.

Requires macOS 13 or later (Apple silicon and Intel).

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask rs2pt/tap/quickmsg
```

Or download `QuickMSG-<version>.zip` from the [releases](https://github.com/rs2pt/QuickMSG/releases),
move `QuickMSG.app` to `/Applications` and open it once so macOS registers the extension.

The app is not notarized (it is ad-hoc signed), so macOS blocks the first launch of a manual download. Either
allow it under System Settings → Privacy & Security → "Open Anyway", or run:

```sh
xattr -dr com.apple.quarantine /Applications/QuickMSG.app
```

The Homebrew cask does this for you. If a preview doesn't show up right away, run `qlmanage -r`.

## Build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project QuickMSG.xcodeproj -scheme QuickMSG -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build
```

Run the tests with `xcodebuild -project QuickMSG.xcodeproj -scheme QuickMSG -derivedDataPath build test`.
Put real `.msg` files in `examples/` (git-ignored) and the tests will parse them too.

## Limitations

- Attachments are listed but not previewed or extracted; embedded `.msg` attachments show by name only.
- No thumbnail extension yet, only the preview.
- Reading is best effort: unreadable or malformed files fail the preview instead of crashing the viewer.

## How it works

`.msg` files are OLE/CFB containers (MS-CFB, MS-OXMSG). There is no dependency; the parsing is in `Shared/`:

- `CFBReader.swift` – container reader
- `MSGParser.swift` – properties, recipients, attachments
- `RTFDecompressor.swift`, `RTFConverter.swift` – compressed RTF, and the HTML Outlook encapsulates in it
- `MSGRenderer.swift` – the HTML page handed to Quick Look

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## License

[MIT](LICENSE)
