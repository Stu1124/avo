import Foundation

/// Lightweight tokenizer for fenced code in the notch. Enough to make JSON, Swift, Python,
/// JavaScript and shell read as code — not a full highlighter.
enum CodeHighlight {
    enum Kind: Equatable { case plain, keyword, string, comment, number, typeName, punctuation }

    struct Token: Equatable {
        var text: String
        var kind: Kind
    }

    static func tokens(_ code: String, language: String?) -> [Token] {
        let lang = (language ?? "").lowercased()
        if lang == "json" { return jsonTokens(code) }
        return genericTokens(code, language: lang)
    }

    // MARK: - JSON

    private static func jsonTokens(_ code: String) -> [Token] {
        var out: [Token] = []
        var i = code.startIndex
        while i < code.endIndex {
            let ch = code[i]
            if ch.isWhitespace {
                var j = i
                while j < code.endIndex, code[j].isWhitespace { j = code.index(after: j) }
                out.append(Token(text: String(code[i..<j]), kind: .plain))
                i = j
                continue
            }
            if ch == "\"" {
                let (tok, next) = scanString(code, from: i)
                out.append(tok)
                i = next
                continue
            }
            if ch == "-" || ch.isNumber {
                var j = i
                if code[j] == "-" { j = code.index(after: j) }
                while j < code.endIndex, code[j].isNumber || code[j] == "." || code[j] == "e" || code[j] == "E" || code[j] == "+" {
                    j = code.index(after: j)
                }
                out.append(Token(text: String(code[i..<j]), kind: .number))
                i = j
                continue
            }
            if ch.isLetter {
                var j = i
                while j < code.endIndex, code[j].isLetter { j = code.index(after: j) }
                let word = String(code[i..<j])
                let kind: Kind = (word == "true" || word == "false" || word == "null") ? .keyword : .plain
                out.append(Token(text: word, kind: kind))
                i = j
                continue
            }
            out.append(Token(text: String(ch), kind: .punctuation))
            i = code.index(after: i)
        }
        return out
    }

    // MARK: - Generic (C-family comments + language keywords)

    private static func genericTokens(_ code: String, language: String) -> [Token] {
        let keywords = Self.keywords[language] ?? Self.keywords[alias(language)] ?? []
        let types = Self.types[language] ?? Self.types[alias(language)] ?? []
        let hashComments = language == "python" || language == "bash" || language == "shell" || language == "sh" || language == "yaml" || language == "toml"
        var out: [Token] = []
        var i = code.startIndex
        while i < code.endIndex {
            let ch = code[i]
            if ch == "\"" || ch == "'" || ch == "`" {
                let (tok, next) = scanString(code, from: i)
                out.append(tok)
                i = next
                continue
            }
            if hashComments, ch == "#" {
                let (tok, next) = scanLineComment(code, from: i)
                out.append(tok)
                i = next
                continue
            }
            if ch == "/", code.index(after: i) < code.endIndex {
                let n = code[code.index(after: i)]
                if n == "/" {
                    let (tok, next) = scanLineComment(code, from: i)
                    out.append(tok)
                    i = next
                    continue
                }
                if n == "*" {
                    let (tok, next) = scanBlockComment(code, from: i)
                    out.append(tok)
                    i = next
                    continue
                }
            }
            if ch.isNumber {
                var j = i
                while j < code.endIndex, code[j].isNumber || code[j] == "." || code[j] == "_" { j = code.index(after: j) }
                out.append(Token(text: String(code[i..<j]), kind: .number))
                i = j
                continue
            }
            if ch.isLetter || ch == "_" {
                var j = i
                while j < code.endIndex, code[j].isLetter || code[j].isNumber || code[j] == "_" { j = code.index(after: j) }
                let word = String(code[i..<j])
                let kind: Kind
                if keywords.contains(word) { kind = .keyword }
                else if types.contains(word) { kind = .typeName }
                else if word.first?.isUppercase == true { kind = .typeName }
                else { kind = .plain }
                out.append(Token(text: word, kind: kind))
                i = j
                continue
            }
            if "{}[]().,;:".contains(ch) {
                out.append(Token(text: String(ch), kind: .punctuation))
                i = code.index(after: i)
                continue
            }
            out.append(Token(text: String(ch), kind: .plain))
            i = code.index(after: i)
        }
        return out
    }

    private static func scanString(_ code: String, from start: String.Index) -> (Token, String.Index) {
        let quote = code[start]
        var i = code.index(after: start)
        var escaped = false
        while i < code.endIndex {
            let ch = code[i]
            if escaped { escaped = false; i = code.index(after: i); continue }
            if ch == "\\" { escaped = true; i = code.index(after: i); continue }
            if ch == quote { i = code.index(after: i); break }
            if ch == "\n", quote != "`" { break }
            i = code.index(after: i)
        }
        return (Token(text: String(code[start..<i]), kind: .string), i)
    }

    private static func scanLineComment(_ code: String, from start: String.Index) -> (Token, String.Index) {
        var i = start
        while i < code.endIndex, code[i] != "\n" { i = code.index(after: i) }
        return (Token(text: String(code[start..<i]), kind: .comment), i)
    }

    private static func scanBlockComment(_ code: String, from start: String.Index) -> (Token, String.Index) {
        var i = code.index(start, offsetBy: 2, limitedBy: code.endIndex) ?? code.endIndex
        while i < code.endIndex {
            if code[i] == "*", code.index(after: i) < code.endIndex, code[code.index(after: i)] == "/" {
                i = code.index(i, offsetBy: 2)
                break
            }
            i = code.index(after: i)
        }
        return (Token(text: String(code[start..<i]), kind: .comment), i)
    }

    private static func alias(_ language: String) -> String {
        switch language {
        case "js", "jsx", "ts", "tsx", "javascript", "typescript": return "javascript"
        case "py": return "python"
        case "sh", "zsh", "shell": return "bash"
        case "c++", "cpp", "cxx": return "cpp"
        case "yml": return "yaml"
        default: return language
        }
    }

    private static let keywords: [String: Set<String>] = [
        "swift": ["let", "var", "func", "if", "else", "guard", "switch", "case", "return", "import", "struct", "class", "enum", "protocol", "extension", "true", "false", "nil", "self", "Self", "await", "async", "throws", "try", "catch", "for", "while", "in", "where", "as", "is", "some", "any", "private", "public", "internal", "static", "override", "init", "deinit", "associatedtype", "typealias"],
        "python": ["def", "class", "if", "elif", "else", "return", "import", "from", "as", "True", "False", "None", "for", "while", "in", "not", "and", "or", "with", "try", "except", "finally", "raise", "yield", "lambda", "pass", "break", "continue", "async", "await", "global", "nonlocal"],
        "javascript": ["const", "let", "var", "function", "if", "else", "return", "import", "from", "export", "default", "class", "extends", "new", "this", "true", "false", "null", "undefined", "async", "await", "try", "catch", "finally", "throw", "for", "while", "of", "in", "switch", "case", "break", "continue", "typeof", "instanceof"],
        "bash": ["if", "then", "else", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "local", "export", "echo", "exit"],
        "cpp": ["int", "void", "class", "struct", "if", "else", "return", "for", "while", "const", "auto", "true", "false", "nullptr", "template", "typename", "public", "private", "protected", "virtual", "override", "namespace", "using"],
    ]

    private static let types: [String: Set<String>] = [
        "swift": ["String", "Int", "Double", "Bool", "Array", "Dictionary", "Optional", "Any", "UUID", "Date", "URL", "Data", "CGFloat", "View", "Color"],
        "python": ["str", "int", "float", "bool", "list", "dict", "tuple", "set", "None"],
        "javascript": ["String", "Number", "Boolean", "Array", "Object", "Promise", "Map", "Set"],
    ]
}
