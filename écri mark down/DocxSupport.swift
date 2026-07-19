import Foundation

/// Minimal, dependency-free .docx (OOXML WordprocessingML) read/write support.
/// Both directions are lossy by design: reading strips all formatting down to
/// plain paragraphs, and writing wraps plain text/Markdown source into plain
/// Word paragraphs (no bold/italic/headings are re-created). Callers are
/// expected to warn the user before writing — see `EditorStore` Save/Save As.
enum DocxSupport {

    // MARK: - Reading

    /// Extract plain paragraph text from a .docx file's `word/document.xml`.
    static func read(url: URL) -> String? {
        #if os(macOS)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", url.path, "-d", tmp.path]
        guard (try? unzip.run()) != nil else { return nil }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { return nil }

        let docXML = tmp.appendingPathComponent("word/document.xml")
        guard let xml = try? String(contentsOf: docXML, encoding: .utf8) else { return nil }
        return extractParagraphs(from: xml)
        #else
        return nil
        #endif
    }

    /// Split `<w:p>…</w:p>` paragraphs, joining their `<w:t>` runs, and separate
    /// paragraphs with blank lines so the result reads sensibly as Markdown/plain text.
    private static func extractParagraphs(from xml: String) -> String {
        var paragraphs: [String] = []
        guard let pRegex = try? NSRegularExpression(pattern: "<w:p[ >][\\s\\S]*?</w:p>") else { return "" }
        let ns = xml as NSString
        pRegex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let pXML = ns.substring(with: match.range)
            paragraphs.append(extractRunText(from: pXML))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func extractRunText(from paragraphXML: String) -> String {
        var text = ""
        guard let tRegex = try? NSRegularExpression(pattern: "<w:t[^>]*>([\\s\\S]*?)</w:t>") else { return "" }
        let ns = paragraphXML as NSString
        tRegex.enumerateMatches(in: paragraphXML, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: paragraphXML) else { return }
            text += unescapeXML(String(paragraphXML[r]))
        }
        // A run break (<w:br/>) inside a paragraph becomes a line break.
        return text
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Writing

    /// Write `content` as a minimal valid .docx — one Word paragraph per line of text.
    /// No Markdown syntax is interpreted; this is a plain-text-to-Word wrap, matching
    /// the formatting-loss warning shown before this is invoked.
    @discardableResult
    static func write(content: String, to url: URL) -> Bool {
        #if os(macOS)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_out_\(UUID().uuidString)")
        let wordDir = tmp.appendingPathComponent("word")
        let relsDir = tmp.appendingPathComponent("_rels")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)

            try contentTypesXML.write(to: tmp.appendingPathComponent("[Content_Types].xml"),
                                       atomically: true, encoding: .utf8)
            try rootRelsXML.write(to: relsDir.appendingPathComponent(".rels"),
                                   atomically: true, encoding: .utf8)
            try documentXML(for: content).write(to: wordDir.appendingPathComponent("document.xml"),
                                                 atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        try? FileManager.default.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tmp
        zip.arguments = ["-q", "-r", "-X", url.path, "."]
        guard (try? zip.run()) != nil else { return false }
        zip.waitUntilExit()
        return zip.terminationStatus == 0
        #else
        return false
        #endif
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func documentXML(for content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let paragraphs = lines.map { line -> String in
            let escaped = escapeXML(line)
            return "<w:p><w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(paragraphs)<w:sectPr/></w:body>
        </w:document>
        """
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """
}
