import Foundation

/// Converts Markdown into speech-friendly SSML: syntax removed, structure turned into pauses.
/// Note: only `<break>` is used — Apple's SSML parser crashes (SIGSEGV) on `<p>`/`<s>` tags (macOS 15.7).
enum Markdown {
    static func toSSML(_ md: String) -> String {
        var out: [String] = []
        var inFence = false
        var paragraph: [String] = []

        func flush() {
            let p = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            if !p.isEmpty { out.append("\(esc(inline(p))) <break time=\"350ms\"/>") }
        }

        for raw in md.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                if !inFence { out.append("Code block omitted. <break time=\"400ms\"/>") }
                inFence.toggle()
                continue
            }
            if inFence { continue }

            if line.isEmpty { flush(); continue }

            // tables: skip separator rows, read cells as a sentence
            if line.hasPrefix("|") {
                flush()
                if line.range(of: #"^\|[\s:|-]+\|$"#, options: .regularExpression) != nil { continue }
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                out.append("\(esc(inline(cells.joined(separator: ", ")))). <break time=\"200ms\"/>")
                continue
            }

            // headings: read text, then a longer pause
            if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let title = String(line[m.upperBound...]).replacingOccurrences(of: #"\s*#+$"#, with: "", options: .regularExpression)
                out.append("<break time=\"600ms\"/>\(esc(inline(title))). <break time=\"500ms\"/>")
                continue
            }
            // horizontal rule
            if line.range(of: #"^([-*_])\s*(\1\s*){2,}$"#, options: .regularExpression) != nil {
                flush(); out.append("<break time=\"800ms\"/>"); continue
            }
            // list items / block quotes: each its own sentence
            if let m = line.range(of: #"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?|^>\s*"#, options: .regularExpression) {
                flush()
                var item = String(line[m.upperBound...])
                if !item.hasSuffix(".") && !item.hasSuffix("!") && !item.hasSuffix("?") && !item.hasSuffix(":") { item += "." }
                out.append("\(esc(inline(item))) <break time=\"250ms\"/>")
                continue
            }
            paragraph.append(line)
        }
        flush()
        return "<speak>" + out.joined(separator: "\n") + "</speak>"
    }

    /// Strip inline Markdown syntax.
    static func inline(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),          // image -> alt text
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),           // link -> text
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),          // ref link
            (#"<https?://[^>]+>"#, ""),                  // autolink
            (#"https?://\S+"#, "link"),                  // bare URL
            (#"`([^`]+)`"#, "$1"),                       // inline code
            (#"(\*\*|__)(.+?)\1"#, "$2"),                // bold
            (#"(\*|_)(.+?)\1"#, "$2"),                   // italic
            (#"~~(.+?)~~"#, "$1"),                       // strike
            (#"<[^>]+>"#, ""),                           // html tags
            (#"\\([\\`*_{}\[\]()#+\-.!])"#, "$1"),       // escapes
            (#"\s{2,}"#, " "),
        ]
        for (p, r) in rules { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
