import Logging

/// Keeps routine service logs on stdout so Railway does not classify them as
/// errors, while preserving warning-and-higher events on stderr.
struct RailwaySeverityLogHandler: LogHandler {
  private var standardOutput: StreamLogHandler
  private var standardError: StreamLogHandler

  var logLevel: Logger.Level = .info {
    didSet {
      standardOutput.logLevel = logLevel
      standardError.logLevel = logLevel
    }
  }

  var metadataProvider: Logger.MetadataProvider? {
    get { standardOutput.metadataProvider }
    set {
      standardOutput.metadataProvider = newValue
      standardError.metadataProvider = newValue
    }
  }

  var metadata: Logger.Metadata = [:] {
    didSet {
      standardOutput.metadata = metadata
      standardError.metadata = metadata
    }
  }

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  init(label: String) {
    standardOutput = .standardOutput(label: label)
    standardError = .standardError(label: label)
  }

  func log(event: LogEvent) {
    if event.level >= .warning {
      standardError.log(event: event)
    } else {
      standardOutput.log(event: event)
    }
  }
}
