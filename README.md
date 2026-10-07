# QuickMSG

Quick Look preview for Outlook `.msg` files on macOS (Quick Look Preview Extension, macOS 13+).

Shows subject, sender, recipients, date, attachment list and the body (HTML, HTML recovered from
Outlook's RTF encapsulation, or plain text). Remote content is blocked and inline images are embedded.

## Build

    brew install xcodegen
    xcodegen generate
    xcodebuild -project QuickMSG.xcodeproj -scheme QuickMSG -configuration Release build

Copy `QuickMSG.app` to `/Applications` and open it once so macOS registers the extension.

## Layout

- `Shared/CFBReader.swift` – OLE/CFB container reader (MS-CFB)
- `Shared/MSGParser.swift` – .msg properties, recipients, attachments (MS-OXMSG)
- `Shared/RTFDecompressor.swift`, `Shared/RTFConverter.swift` – compressed RTF and HTML de-encapsulation
- `Shared/MSGRenderer.swift` – HTML page for Quick Look
