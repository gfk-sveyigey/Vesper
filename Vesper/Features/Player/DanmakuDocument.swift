import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct DanmakuComment: Sendable {
    let time: Double
    let mode: Int
    let color: UInt32
    let text: String
}

enum DanmakuImportError: LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: "无法读取弹幕。请选择包含有效弹幕的 Bilibili XML 文件。"
        case .tooLarge: "弹幕文件过大，最多支持 16 MB、50000 条弹幕。"
        }
    }
}

/// No external entities or network access. Only scrolling/top/bottom text modes.
final class DanmakuXMLParser: NSObject, XMLParserDelegate {
    private var comments: [DanmakuComment] = []
    private var parameters: [String]?
    private var text = ""
    private var overflow = false

    static func parse(_ data: Data) throws -> [DanmakuComment] {
        guard data.count <= 16 * 1024 * 1024 else { throw DanmakuImportError.tooLarge }
        let delegate = DanmakuXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let valid = parser.parse()
        if delegate.overflow { throw DanmakuImportError.tooLarge }
        guard valid, !delegate.comments.isEmpty else { throw DanmakuImportError.invalid }
        return delegate.comments.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "d" {
            parameters = attributes["p"]?.components(separatedBy: ",")
            text = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if parameters != nil, text.count < 500 { text += String(string.prefix(500 - text.count)) }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) {
            self.parser(parser, foundCharacters: value)
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard elementName == "d", let p = parameters else { return }
        parameters = nil
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count >= 4, let time = Double(p[0]), time.isFinite, time >= 0,
              let mode = Int(p[1]), [1, 2, 3, 4, 5].contains(mode),
              let color = UInt32(p[3]), color <= 0xFFFFFF, !content.isEmpty else { return }
        guard comments.count < 50_000 else { overflow = true; parser.abortParsing(); return }
        comments.append(.init(time: time, mode: mode, color: color, text: content))
    }
}

/// Deterministic, playback-clock-based layout; shared by seeks and live rendering.
struct DanmakuDisplayOptions: Sendable {
    var fontSize = 22.0
    var speed = 1.0
    var area = 0.5
    var density = 2
    var scrolling = true
    var top = true
    var bottom = true
    var colored = true
    var bold = false
    var shadow = true
    var avoidSubtitles = true
    var filterDuplicates = true
    var blockedWords = ""

    var keywords: [String] {
        blockedWords.components(separatedBy: CharacterSet(charactersIn: "\n,，;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

struct DanmakuPlacement {
    let comment: DanmakuComment
    let width: Double
    let y: Double
    let lifetime: Double
    var scrolling: Bool { comment.mode != 4 && comment.mode != 5 }
}

enum DanmakuLayout {
    static func build(comments: [DanmakuComment], width: Double, height: Double,
                      options: DanmakuDisplayOptions, measure: (String) -> Double) -> [DanmakuPlacement] {
        guard width > 0, height > 0 else { return [] }
        let fontSize = min(40, max(14, options.fontSize))
        let rowHeight = fontSize + 8
        let topInset = 24.0
        let bottomInset = options.avoidSubtitles ? 100.0 : 24.0
        let usable = max(0, height - topInset - bottomInset)
        let regionHeight = usable * min(1, max(0.25, options.area))
        let totalRows = min(32, Int(regionHeight / rowHeight))
        guard totalRows > 0 else { return [] }
        let density = min(3, max(1, options.density))
        let count = max(1, Int(Double(totalRows) * Double(density) / 3))
        // Spread reduced-density lanes throughout the selected region.
        let rows = (0..<count).map { min(totalRows - 1, $0 * totalRows / count) }
        var available = Array(repeating: -Double.infinity, count: count)
        var seen: [String: Double] = [:]
        let keywords = options.keywords
        let speed = min(2, max(0.5, options.speed))
        var result: [DanmakuPlacement] = []
        for comment in comments {
            let scrolling = comment.mode != 4 && comment.mode != 5
            guard scrolling ? options.scrolling : (comment.mode == 4 ? options.bottom : options.top) else { continue }
            guard !keywords.contains(where: { comment.text.localizedCaseInsensitiveContains($0) }) else { continue }
            let normalized = comment.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if options.filterDuplicates, let previous = seen[normalized], comment.time - previous < 10 { continue }
            let candidates = comment.mode == 4 ? Array((0..<count).reversed()) : Array(0..<count)
            guard let lane = candidates.first(where: { available[$0] <= comment.time }) else { continue }
            let textWidth = max(1, measure(comment.text))
            let lifetime = (scrolling ? 8.0 : 4.0) / speed
            available[lane] = comment.time + lifetime + 0.15
            seen[normalized] = comment.time
            let y = topInset + rowHeight / 2 + Double(rows[lane]) * rowHeight
            result.append(.init(comment: comment, width: textWidth, y: y, lifetime: lifetime))
        }
        return result
    }
}
