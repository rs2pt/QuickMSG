import Cocoa
import Quartz
import UniformTypeIdentifiers

/// Data-based Quick Look preview: parses the .msg and hands HTML back to Quick Look.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let html = MSGRenderer.html(for: try MSGParser.parse(data))
        let htmlData = Data(html.utf8)

        let reply = QLPreviewReply(dataOfContentType: .html,
                                   contentSize: CGSize(width: 820, height: 1000)) { _ in
            htmlData
        }
        reply.stringEncoding = .utf8
        return reply
    }
}
