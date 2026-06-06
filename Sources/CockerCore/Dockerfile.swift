import Foundation

public struct DockerfileInstruction: Sendable {
    public let keyword: String
    public let args: String
    public init(keyword: String, args: String) {
        self.keyword = keyword
        self.args = args
    }
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

    guard instructions.first?.keyword == "FROM" else {
        throw CockerError.invalidDockerfileInstruction("Dockerfile must start with FROM")
    }

    return instructions
}
