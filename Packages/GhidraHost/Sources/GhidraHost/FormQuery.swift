import Foundation

/// A query string the owner and the server read back exactly.
///
/// Both decode a query as a form does, `+` as a space (`URLDecoder` in the
/// owner, `HTTPParser` in the server), while `URLComponents` leaves a `+` in a
/// value as it is: `section: "SMM + DXE"` arrived as "SMM   DXE". Every query
/// the host, the server and the app's remote build goes through here.
public enum FormQuery {
    /// `name=value&…`, the names sorted, each name and value percent-encoded
    /// past the unreserved characters — `+` as `%2B`. Empty for no pairs.
    public static func encode(_ pairs: [String: String?]) -> String {
        pairs.keys.sorted().map { name in
            guard let value = pairs[name] ?? nil else { return escaped(name) }
            return escaped(name) + "=" + escaped(value)
        }.joined(separator: "&")
    }

    /// Only the unreserved characters stay as they are: `+`, `&`, `=` and the
    /// rest are percent-encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/:")

    private static func escaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}
