import Foundation

/// Loads key/value pairs from a dotenv file and merges them with the process environment.
///
/// **Precedence:** values already set in the process environment (shell, Docker, CI) **override** the file,
/// matching common `.env` tooling.
enum AppEnvironmentLoader {
  /// Reads `.env` from the current working directory, or from `DOTENV_PATH` if set (relative or absolute).
  /// Missing or unreadable file is ignored.
  static func mergeProcessWithDotenv(
    fileManager: FileManager = .default
  ) -> [String: String] {
    let env = ProcessInfo.processInfo.environment
    let rawPath = env["DOTENV_PATH"] ?? ".env"
    let path: String = {
      if rawPath.hasPrefix("/") { return rawPath }
      return fileManager.currentDirectoryPath + "/" + rawPath
    }()

    guard fileManager.isReadableFile(atPath: path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let text = String(data: data, encoding: .utf8)
    else {
      return env
    }

    let fromFile = parseDotenv(text)
    return mergeDotenvFile(fromFile, into: env)
  }

  /// Applies dotenv key-values, then overlays the process environment so shell/CI values override the file.
  static func mergeDotenvFile(_ fromFile: [String: String], into process: [String: String]) -> [String: String] {
    if fromFile.isEmpty { return process }
    var merged = fromFile
    for (k, v) in process {
      merged[k] = v
    }
    return merged
  }

  /// Minimal dotenv parser: `KEY=value`, optional surrounding quotes, `#` line comments, `export ` prefix.
  static func parseDotenv(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      var trimmed = String(line).trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      if trimmed.hasPrefix("export ") {
        trimmed = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
      }
      guard let eq = trimmed.firstIndex(of: "=") else { continue }
      let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
      if key.isEmpty { continue }
      var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      value = unquote(value)
      out[key] = value
    }
    return out
  }

  private static func unquote(_ value: String) -> String {
    if value.count >= 2 {
      if value.hasPrefix("\""), value.hasSuffix("\"") {
        return String(value.dropFirst().dropLast())
          .replacingOccurrences(of: "\\\"", with: "\"")
          .replacingOccurrences(of: "\\n", with: "\n")
      }
      if value.hasPrefix("'"), value.hasSuffix("'") {
        return String(value.dropFirst().dropLast())
      }
    }
    return value
  }
}
