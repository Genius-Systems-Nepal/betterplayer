import Foundation

/// CTA-5004 CMCD for iOS AVPlayer.
///
/// Limitation: native HLS segment/playlist fetches are not interceptable without a custom
/// AVAssetResourceLoader proxy (conflicts with FairPlay). This helper only tags the
/// **initial** media URL (query mode) and/or static asset HTTP headers (header mode).
@objc public class CmcdHelper: NSObject {

    @objc(isActiveWithConfig:)
    public static func isActive(config: NSDictionary?) -> Bool {
        guard let config = config else {
            return false
        }
        let enabled = boolValue(config["enabled"])
        let mode = ((config["mode"] as? String) ?? "").lowercased()
        return enabled && (mode == "query" || mode == "header")
    }

    /// Appends CMCD= payload to the initial media URL when mode is query.
    @objc(taggedURLFrom:config:)
    public static func taggedURL(from url: URL, config: NSDictionary?) -> URL {
        guard let config = config, isActive(config: config) else {
            NSLog("[CMCD] iOS skip taggedURL (inactive)")
            return url
        }
        let mode = ((config["mode"] as? String) ?? "").lowercased()
        guard mode == "query" else {
            NSLog("[CMCD] iOS skip query tag (mode=%@)", mode)
            return url
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           items.contains(where: { $0.name == "CMCD" }) {
            NSLog("[CMCD] iOS already has CMCD on %@", truncate(url.absoluteString))
            return url
        }
        let payload = buildPayload(config: config, objectType: "m", streamingFormat: streamingFormat(for: url))
        guard !payload.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "CMCD", value: payload))
        components.queryItems = items
        let tagged = components.url ?? url
        NSLog(
            "[CMCD] iOS initial URL mode=query sid=%@ cid=%@ uri=%@",
            stringValue(config["sessionId"]),
            stringValue(config["contentId"]),
            truncate(tagged.absoluteString)
        )
        return tagged
    }

    /// Static CMCD-* headers for AVURLAssetHTTPHeaderFieldsKey (header mode only).
    @objc(httpHeadersMerging:config:url:)
    public static func httpHeaders(merging existing: NSDictionary?, config: NSDictionary?, url: URL) -> NSDictionary {
        var headers: [String: String] = [:]
        if let existing = existing as? [String: String] {
            headers.merge(existing) { _, new in
                new
            }
        } else if let existing = existing as? [AnyHashable: Any] {
            for (k, v) in existing {
                if let key = k as? String {
                    headers[key] = "\(v)"
                }
            }
        }
        guard let config = config, isActive(config: config) else {
            return headers as NSDictionary
        }
        let mode = ((config["mode"] as? String) ?? "").lowercased()
        guard mode == "header" else {
            return headers as NSDictionary
        }
        let keys = payloadKeys(config: config, objectType: "m", streamingFormat: streamingFormat(for: url))
        if let object = pick(keys, "br", "d", "ot", "tb"), !object.isEmpty {
            headers["CMCD-Object"] = object
        }
        if let request = pick(keys, "bl", "dl", "mtp", "su"), !request.isEmpty {
            headers["CMCD-Request"] = request
        }
        if let session = pick(keys, "cid", "pr", "sf", "sid", "st", "v"), !session.isEmpty {
            headers["CMCD-Session"] = session
        }
        if let status = pick(keys, "bs"), !status.isEmpty {
            headers["CMCD-Status"] = status
        }
        NSLog(
            "[CMCD] iOS initial headers mode=header sid=%@ cid=%@",
            stringValue(config["sessionId"]),
            stringValue(config["contentId"])
        )
        return headers as NSDictionary
    }

    private static func truncate(_ text: String) -> String {
        if text.count <= 220 {
            return text
        }
        let idx = text.index(text.startIndex, offsetBy: 220)
        return String(text[..<idx]) + "…"
    }

    private static func streamingFormat(for url: URL) -> String {
        let path = url.path.lowercased()
        if path.contains(".m3u8") || path.contains("hls") {
            return "h"
        }
        if path.contains(".mpd") || path.contains("dash") {
            return "d"
        }
        return "o"
    }

    private static func buildPayload(config: NSDictionary, objectType: String, streamingFormat: String) -> String {
        let keys = payloadKeys(config: config, objectType: objectType, streamingFormat: streamingFormat)
        return keys.map { key, value in
            if let value = value {
                return "\(key)=\(value)"
            }
            return key
        }
        .joined(separator: ",")
    }

    private static func payloadKeys(config: NSDictionary, objectType: String, streamingFormat: String) -> [(String, String?)] {
        var keys: [(String, String?)] = []
        let sid = stringValue(config["sessionId"])
        if !sid.isEmpty {
            keys.append(("sid", quote(sid)))
        }
        let cid = stringValue(config["contentId"])
        if !cid.isEmpty {
            keys.append(("cid", quote(cid)))
        }
        keys.append(("ot", objectType))
        keys.append(("sf", streamingFormat))
        keys.append(("st", boolValue(config["isLive"]) ? "l" : "v"))
        keys.append(("su", nil))
        return keys
    }

    private static func pick(_ keys: [(String, String?)], _ names: String...) -> String? {
        let wanted = Set(names)
        let parts = keys.compactMap { key, value -> String? in
            guard wanted.contains(key) else {
                return nil
            }
            if let value = value {
                return "\(key)=\(value)"
            }
            return key
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value = value else {
            return ""
        }
        let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "null" ? "" : text
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let b = value as? Bool {
            return b
        }
        if let n = value as? NSNumber {
            return n.intValue != 0
        }
        let text = stringValue(value).lowercased()
        return text == "true" || text == "1"
    }
}
