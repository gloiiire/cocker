import Foundation

public struct DockerfileInstruction: Sendable {
    public let keyword: String
    public let args: String
    public init(keyword: String, args: String) {
        self.keyword = keyword
        self.args = args
    }
}

/// Parse the two Dockerfile ENV forms:
///   ENV KEY=value OTHER="value with spaces"
///   ENV KEY value with spaces   (legacy, one variable only)
///
/// Line continuations have already been folded by `parseDockerfile`. This
/// tokenizer keeps quoted or escaped spaces inside one assignment so a
/// multiline ENV does not accidentally store every following assignment in
/// the first variable's value.
public func parseDockerfileEnv(_ raw: String) -> [(key: String, value: String)] {
    let words = dockerfileWords(raw)
    guard let first = words.first else { return [] }

    if first.contains("=") {
        return words.compactMap { word in
            guard let separator = word.firstIndex(of: "=") else { return nil }
            let key = String(word[..<separator])
            guard !key.isEmpty else { return nil }
            return (key, String(word[word.index(after: separator)...]))
        }
    }

    guard words.count > 1 else { return [] }
    return [(first, words.dropFirst().joined(separator: " "))]
}

private func dockerfileWords(_ raw: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    var tokenStarted = false

    for character in raw {
        if escaped {
            current.append(character)
            escaped = false
            tokenStarted = true
            continue
        }
        if character == "\\" {
            escaped = true
            tokenStarted = true
            continue
        }
        if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
            } else {
                current.append(character)
            }
            tokenStarted = true
            continue
        }
        if character == "\"" || character == "'" {
            quote = character
            tokenStarted = true
        } else if character.isWhitespace {
            if tokenStarted {
                words.append(current)
                current = ""
                tokenStarted = false
            }
        } else {
            current.append(character)
            tokenStarted = true
        }
    }
    if escaped { current.append("\\") }
    if tokenStarted { words.append(current) }
    return words
}

public func parseDockerfile(_ content: String) throws -> [DockerfileInstruction] {
    var instructions: [DockerfileInstruction] = []
    var currentLine = ""

    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        if trimmed.hasSuffix("\\") {
            currentLine += trimmed.dropLast() + " "
            continue
        }
        currentLine += trimmed

        let parts = currentLine.split(separator: " ", maxSplits: 1)
        guard parts.count >= 1 else { currentLine = ""; continue }

        let keyword = String(parts[0]).uppercased()
        let args = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        instructions.append(DockerfileInstruction(keyword: keyword, args: args))
        currentLine = ""
    }

    // Standard Dockerfile syntax allows any number of `ARG` lines BEFORE the
    // first FROM — they declare build args that can be substituted in the
    // FROM line itself (e.g. `FROM alpine:${TAG}`). Skip them when locating
    // the first "real" instruction.
    let firstNonArg = instructions.first { $0.keyword != "ARG" }
    guard firstNonArg?.keyword == "FROM" else {
        throw CockerError.invalidDockerfileInstruction("Dockerfile must start with FROM")
    }

    return instructions
}
