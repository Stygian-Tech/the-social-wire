/// Thrown when a string does not satisfy an AT Protocol identifier syntax.
public enum SyntaxError: Error, Equatable, Sendable {
    case invalidDID(String)
    case invalidHandle(String)
    case invalidNSID(String)
    case invalidATURI(String)
    case invalidRecordKey(String)
    case invalidTID(String)
}
