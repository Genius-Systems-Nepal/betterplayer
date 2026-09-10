import UIKit
import AVFoundation
import Alamofire

@objc public class BetterPlayerVuDrmAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    var certificateURL: String?
    var licenseURL: URL?
    var fairPlayToken: String?

    @objc public init(certificateURL: String? = nil, licenseURL: URL? = nil, fairPlayToken: String? = nil) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        self.fairPlayToken = fairPlayToken
        super.init()
        let certPreview = Self.previewCertificateValue(certificateURL ?? "")
        let licensePreview = licenseURL?.absoluteString ?? "(nil)"
        let hasToken = !(fairPlayToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        NSLog("[BetterPlayer-FairPlay] VuDRM delegate init certificateUrl=%@ licenseUrl=%@ hasToken=%@",
              certPreview, licensePreview, hasToken ? "YES" : "NO")
    }

    private static func previewCertificateValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(empty)" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        let previewLength = min(32, trimmed.count)
        let prefix = String(trimmed.prefix(previewLength))
        return "\(prefix)... (\(trimmed.count) chars, inline base64)"
    }

    private var normalizedFairPlayToken: String? {
        guard let token = fairPlayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              token.caseInsensitiveCompare("null") != .orderedSame else {
            return nil
        }
        return token
    }

    private func isRemoteCertificateUrl(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private func sanitizeInlineCertificate(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.contains("-----BEGIN CERTIFICATE-----") {
            cleaned = cleaned
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        } else {
            cleaned = cleaned.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        }
        return cleaned
    }

    private func decodeInlineCertificate(_ value: String) -> Data? {
        let sanitized = sanitizeInlineCertificate(value)
        NSLog("[BetterPlayer-FairPlay] Decoding inline certificateUrl: rawLength=%d sanitizedLength=%d preview=%@",
              value.count, sanitized.count, Self.previewCertificateValue(value))

        if sanitized.isEmpty {
            NSLog("[BetterPlayer-FairPlay] Inline certificate decode failed: sanitized value is empty")
            return nil
        }

        if let decoded = Data(base64Encoded: sanitized, options: [.ignoreUnknownCharacters]), !decoded.isEmpty {
            NSLog("[BetterPlayer-FairPlay] Inline certificate decoded via standard base64 (%d bytes)", decoded.count)
            return decoded
        }

        let urlSafe = sanitized
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = urlSafe.count % 4
        let padded = padding == 0 ? urlSafe : urlSafe + String(repeating: "=", count: 4 - padding)
        if let decoded = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]), !decoded.isEmpty {
            NSLog("[BetterPlayer-FairPlay] Inline certificate decoded via URL-safe base64 (%d bytes)", decoded.count)
            return decoded
        }

        if let decoded = extractCertificateData(from: sanitized.data(using: .utf8)), !decoded.isEmpty {
            NSLog("[BetterPlayer-FairPlay] Inline certificate decoded via extractCertificateData (%d bytes)", decoded.count)
            return decoded
        }

        NSLog("[BetterPlayer-FairPlay] Inline certificate decode failed for sanitizedLength=%d", sanitized.count)
        return nil
    }

    private func loadCertificate(completion: @escaping (Data?) -> Void) {
        let rawCertificateValue = (certificateURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCertificateValue.isEmpty else {
            NSLog("[BetterPlayer-FairPlay] Certificate load failed: certificateUrl is empty")
            completion(nil)
            return
        }

        if !isRemoteCertificateUrl(rawCertificateValue) {
            NSLog("[BetterPlayer-FairPlay] certificateUrl type=inline-base64 (SonyLiv/ExpressPlay path)")
            completion(decodeInlineCertificate(rawCertificateValue))
            return
        }

        let certificateValue = sanitizeInlineCertificate(rawCertificateValue)
        NSLog("[BetterPlayer-FairPlay] certificateUrl type=remote-url value=%@", certificateValue)
        var headers: HTTPHeaders = [:]
        if let token = normalizedFairPlayToken {
            headers["x-vudrm-token"] = token
            headers["nv-authorizations"] = token
        }
        request(certificateValue, method: .get, headers: headers).validate().responseData { response in
            if let error = response.error {
                NSLog("[BetterPlayer-FairPlay] Certificate fetch failed: %@", error.localizedDescription)
                completion(nil)
                return
            }
            let certificateData = extractCertificateData(from: response.value)
            if let certificateData = certificateData {
                NSLog("[BetterPlayer-FairPlay] Remote certificate fetched successfully (%d bytes)", certificateData.count)
            } else {
                NSLog("[BetterPlayer-FairPlay] Remote certificate response could not be parsed")
            }
            completion(certificateData)
        }
    }

    private func processKeyRequest(_ loadingRequest: AVAssetResourceLoadingRequest, certificateData: Data) {
        guard let licenseUrl = loadingRequest.request.url else {
            loadingRequest.finishLoading()
            NSLog("[BetterPlayer-FairPlay] Failed to extract skd license url from loading request")
            return
        }
        NSLog("[BetterPlayer-FairPlay] skd resource url: %@", licenseUrl.absoluteString)

        let contentId = extractContentId(from: licenseUrl) ?? licenseUrl.absoluteString
        guard
            let contentIdData = contentId.data(using: .utf8),
            let spcData = try? loadingRequest.streamingContentKeyRequestData(forApp: certificateData, contentIdentifier: contentIdData, options: nil),
            let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            NSLog("[BetterPlayer-FairPlay] Failed to create SPC (contentId=%@)", contentId)
            return
        }
        NSLog("[BetterPlayer-FairPlay] SPC created (contentId=%@, spcBytes=%d)", contentId, spcData.count)

        let fallbackLicenseURL = licenseUrl.absoluteString.replacingOccurrences(of: "skd", with: "https")
        let targetLicenseURLString = licenseURL?.absoluteString ?? fallbackLicenseURL
        guard let targetLicenseURL = URL(string: targetLicenseURLString) else {
            NSLog("[BetterPlayer-FairPlay] Failed to parse license server url: %@", targetLicenseURLString)
            loadingRequest.finishLoading()
            return
        }
        NSLog("[BetterPlayer-FairPlay] Posting SPC to license server: %@", targetLicenseURL.absoluteString)

        var urlRequest = URLRequest(url: targetLicenseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = spcData
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token = normalizedFairPlayToken {
            urlRequest.setValue(token, forHTTPHeaderField: "nv-authorizations")
            urlRequest.setValue(token, forHTTPHeaderField: "x-vudrm-token")
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            NSLog("[BetterPlayer-FairPlay] License request includes drm token")
        }

        request(urlRequest).validate().responseData { response in
            if let error = response.error {
                NSLog("[BetterPlayer-FairPlay] CKC fetch failed: %@", error.localizedDescription)
                loadingRequest.finishLoading()
                return
            }

            if let data = response.value {
                if let ckcData = extractCkcData(from: data) {
                    NSLog("[BetterPlayer-FairPlay] CKC fetched successfully (%d bytes)", ckcData.count)
                    dataRequest.respond(with: ckcData)
                } else {
                    NSLog("[BetterPlayer-FairPlay] Failed to parse CKC response (%d bytes)", data.count)
                }
            } else {
                NSLog("[BetterPlayer-FairPlay] CKC response was empty")
            }
            loadingRequest.finishLoading()
        }
    }
    
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        NSLog("[BetterPlayer-FairPlay] FairPlay key request started")
        loadCertificate { [weak self] certificateData in
            guard let self = self else {
                loadingRequest.finishLoading()
                return
            }
            guard let certificateData = certificateData else {
                NSLog("[BetterPlayer-FairPlay] FairPlay key request aborted: certificate decode returned nil")
                loadingRequest.finishLoading()
                return
            }
            NSLog("[BetterPlayer-FairPlay] Certificate ready for SPC (%d bytes)", certificateData.count)
            self.processKeyRequest(loadingRequest, certificateData: certificateData)
        }

        return true
    }
}

func extractCkcData(from responseData: Data) -> Data? {
    if
        let jsonObject = try? JSONSerialization.jsonObject(with: responseData, options: []),
        let json = jsonObject as? [String: Any] {
        let supportedKeys = ["CkcMessage", "ckcMessage", "CKCMessage", "ckc", "CKC"]
        for key in supportedKeys {
            if let ckcMessage = json[key] as? String {
                return Data(base64Encoded: ckcMessage, options: [.ignoreUnknownCharacters]) ?? responseData
            }
        }
    }

    if
        let responseString = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        let base64Data = Data(base64Encoded: responseString, options: [.ignoreUnknownCharacters]) {
        return base64Data
    }

    return responseData
}

func extractCertificateData(from responseData: Data?) -> Data? {
    guard let responseData = responseData else {
        NSLog("[BetterPlayer-FairPlay] extractCertificateData: input is nil")
        return nil
    }

    if
        let jsonObject = try? JSONSerialization.jsonObject(with: responseData, options: []),
        let json = jsonObject as? [String: Any] {
        let supportedKeys = ["certificate", "Certificate", "cert", "CertMessage", "CertificateMessage"]
        for key in supportedKeys {
            if let certValue = json[key] as? String,
               let certData = Data(base64Encoded: certValue, options: [.ignoreUnknownCharacters]) {
                NSLog("[BetterPlayer-FairPlay] extractCertificateData: decoded JSON key '%@' (%d bytes)", key, certData.count)
                return certData
            }
        }
    }

    if
        let responseString = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        let base64Data = Data(base64Encoded: responseString, options: [.ignoreUnknownCharacters]),
        !base64Data.isEmpty {
        NSLog("[BetterPlayer-FairPlay] extractCertificateData: decoded base64 string (%d bytes)", base64Data.count)
        return base64Data
    }

    if !responseData.isEmpty {
        NSLog("[BetterPlayer-FairPlay] extractCertificateData: using raw response data (%d bytes)", responseData.count)
    }
    return responseData.isEmpty ? nil : responseData
}

func extractContentId(from skdURL: URL) -> String? {
    let skdString = skdURL.absoluteString
    guard skdString.hasPrefix("skd://") else {
        return skdURL.lastPathComponent
    }

    let payloadPart = skdString.replacingOccurrences(of: "skd://", with: "")
        .components(separatedBy: "?")
        .first ?? ""
    guard !payloadPart.isEmpty else {
        return nil
    }

    if
        let payloadData = Data(base64Encoded: payloadPart, options: [.ignoreUnknownCharacters]),
        let decodedPayload = String(data: payloadData, encoding: .utf8),
        !decodedPayload.isEmpty {
        // JS FairPlay sample uses full decoded payload from skd:// as asset id.
        return decodedPayload
    }

    return payloadPart
}
