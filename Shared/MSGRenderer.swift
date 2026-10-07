import Foundation

/// Turns a parsed message into a self-contained HTML page for Quick Look.
enum MSGRenderer {

    static func html(for msg: MSGMessage) -> String {
        let body = bodyHTML(for: msg)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:">
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, Helvetica, sans-serif; margin: 0; }
        .head { padding: 16px 20px 12px; border-bottom: 1px solid rgba(128,128,128,.35); }
        .subject { font-size: 20px; font-weight: 600; margin: 0 0 10px; }
        table.meta { border-collapse: collapse; font-size: 13px; }
        table.meta td { padding: 1px 0; vertical-align: top; }
        table.meta td.k { color: gray; padding-right: 12px; text-align: right; white-space: nowrap; }
        .atts { margin-top: 10px; font-size: 12px; }
        .att { display: inline-block; padding: 2px 8px; margin: 2px 6px 2px 0; border: 1px solid rgba(128,128,128,.4); border-radius: 10px; }
        .body { padding: 16px 20px; }
        pre.plain { font: 13px ui-monospace, Menlo, monospace; white-space: pre-wrap; word-wrap: break-word; margin: 0; }
        </style></head><body>
        <div class="head">
        <h1 class="subject">\(esc(msg.subject.isEmpty ? "(sem assunto)" : msg.subject))</h1>
        <table class="meta">\(metaRows(for: msg))</table>
        \(attachmentChips(msg.attachments))
        </div>
        <div class="body">\(body)</div>
        </body></html>
        """
    }

    // MARK: Header

    private static func metaRows(for msg: MSGMessage) -> String {
        var rows = ""
        func row(_ k: String, _ v: String) { if !v.isEmpty { rows += "<tr><td class=\"k\">\(k)</td><td>\(esc(v))</td></tr>" } }
        row("De", format(name: msg.senderName, address: msg.senderAddress))
        row("Para", list(msg.recipients, .to))
        row("Cc", list(msg.recipients, .cc))
        row("Bcc", list(msg.recipients, .bcc))
        if let date = msg.date {
            let f = DateFormatter()
            f.dateStyle = .full
            f.timeStyle = .short
            row("Data", f.string(from: date))
        }
        return rows
    }

    private static func list(_ all: [MSGMessage.Recipient], _ kind: MSGMessage.Recipient.Kind) -> String {
        all.filter { $0.kind == kind }.map { format(name: $0.name, address: $0.address) }.joined(separator: "; ")
    }

    private static func format(name: String, address: String) -> String {
        switch (name.isEmpty, address.isEmpty) {
        case (_, true): return name
        case (true, false): return address
        default: return name == address ? address : "\(name) <\(address)>"
        }
    }

    private static func attachmentChips(_ atts: [MSGMessage.Attachment]) -> String {
        let shown = atts.filter { !$0.isInline }
        guard !shown.isEmpty else { return "" }
        let chips = shown.map { a in
            let size = a.size > 0 ? " · " + ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file) : ""
            return "<span class=\"att\">\(esc(a.fileName))\(size)</span>"
        }.joined()
        return "<div class=\"atts\">\(chips)</div>"
    }

    // MARK: Body

    private static func bodyHTML(for msg: MSGMessage) -> String {
        if let html = msg.htmlBody { return inlineImages(in: html, of: msg) }
        if let rtf = msg.rtfBody {
            switch RTFConverter.convert(rtf) {
            case .html(let html) where !html.isEmpty: return inlineImages(in: html, of: msg)
            case .text(let text) where !text.isEmpty: return "<pre class=\"plain\">\(esc(text))</pre>"
            default: break
            }
        }
        if let plain = msg.plainBody {
            return "<pre class=\"plain\">\(esc(plain))</pre>"
        }
        return "<p style=\"color:gray\">(mensagem sem corpo)</p>"
    }

    /// Replaces `cid:` references with the attachment bytes, since the page may not load anything else.
    private static func inlineImages(in html: String, of msg: MSGMessage) -> String {
        var html = html
        for a in msg.attachments {
            guard let cid = a.contentID, let data = a.data else { continue }
            let mime = a.mimeType ?? "application/octet-stream"
            html = html.replacingOccurrences(of: "cid:\(cid)", with: "data:\(mime);base64,\(data.base64EncodedString())",
                                             options: .caseInsensitive)
        }
        return html
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
