import Foundation

/// What the store refuses, and why. A string rather than an underlying error:
/// the store's failures are about names, hashes and files it was asked for,
/// and the caller shows them as they are.
public enum CodeAnalysisError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDigest(String)
    case invalidName(String)
    case invalidRecipe(String)
    case objectMissing(String)
    case objectCorrupt(String)
    case analysisMissing(String)
    case analysisMismatch(String)
    case bundleInvalid(String)
    case io(String)

    public var description: String {
        switch self {
        case .invalidDigest(let text):
            return "\(text) is not a SHA-256"
        case .invalidName(let text):
            return "\(text) is not a store name"
        case .invalidRecipe(let text):
            return "\(text) is not a recipe name"
        case .objectMissing(let digest):
            return "object \(digest) is missing"
        case .objectCorrupt(let digest):
            return "object \(digest) does not match its hash"
        case .analysisMissing(let key):
            return "no analysis for \(key)"
        case .analysisMismatch(let text):
            return text
        case .bundleInvalid(let text):
            return "bundle: \(text)"
        case .io(let text):
            return text
        }
    }
}
