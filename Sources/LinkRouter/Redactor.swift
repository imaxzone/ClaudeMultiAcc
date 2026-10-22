import Foundation
import Support

/// Log-safe rendering of a link (G13): `claude://<host>/<path>` with query values → `<redacted>` (keys kept),
/// fragment → `#<redacted>`, emails → `<email>`, path segments over 40 chars → first 8 + `…`; then `SecretRedactor`.
public enum Redactor {
  static let maxSegment = 40
  static let keptPrefix = 8
  static let placeholder = "<redacted>"

  public static func redact(_ url: URL) -> String {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let scheme = (url.scheme ?? "unknown").lowercased()
    let host = (components?.host ?? "").lowercased()
    let segments = (components?.percentEncodedPath ?? "").split(separator: "/").map { segment(String($0)) }
    var text = "\(scheme)://\(host)" + (segments.isEmpty ? "" : "/" + segments.joined(separator: "/"))
    if let items = components?.percentEncodedQueryItems, !items.isEmpty {
      text += "?" + items.map { item in
        let key = segment(item.name)
        return item.value == nil ? key : "\(key)=\(placeholder)"
      }.joined(separator: "&")
    }
    if components?.fragment != nil { text += "#\(placeholder)" }
    return SecretRedactor.redact(text)
  }

  /// Truncates long values and masks addresses; session ids stay recognisable by their prefix.
  public static func segment(_ raw: String) -> String {
    let decoded = raw.removingPercentEncoding ?? raw
    if decoded.contains("@") { return "<email>" }
    return decoded.count > maxSegment ? String(decoded.prefix(keptPrefix)) + "…" : raw
  }
}
