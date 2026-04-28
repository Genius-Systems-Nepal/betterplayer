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
    }

    private var normalizedFairPlayToken: String? {
        guard let token = fairPlayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              token.caseInsensitiveCompare("null") != .orderedSame else {
            return nil
        }
        return token
    }
    
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        let url = self.certificateURL ?? ""
        var headers: HTTPHeaders = [:]
        if let token = self.normalizedFairPlayToken {
            headers["x-vudrm-token"] = token
            headers["nv-authorizations"] = token
        }
        request(url, method: .get, headers: headers).validate().responseData { [weak self] response in
            guard let self = self else {
                loadingRequest.finishLoading()
                return
            }
            if let error = response.error {
                print("❌ Error on fetching certificate! -> \(error.localizedDescription)")
                loadingRequest.finishLoading()
                return
            }
            let certificateData = extractCertificateData(from: response.value)
            
            guard let licenseUrl = loadingRequest.request.url else {
                loadingRequest.finishLoading()
                print("❌ Error on extracting license url!")
                return
            }
            print("✅ License url validation passed: -> \(licenseUrl)")
            
            // create SPC Message
            let contentId = extractContentId(from: licenseUrl) ?? licenseUrl.absoluteString
            guard
                let certificateData = certificateData,
                let contentIdData = contentId.data(using: .utf8),
                let spcData = try? loadingRequest.streamingContentKeyRequestData(forApp: certificateData, contentIdentifier: contentIdData, options: nil),
                let dataRequest = loadingRequest.dataRequest else {
                    loadingRequest.finishLoading()
                print("❌ Error on creating SPC Message! contentId: \(contentId)")
                    return
            }
            
            // get CKC
            let fallbackLicenseURL = licenseUrl.absoluteString.replacingOccurrences(of: "skd", with: "https")
            let targetLicenseURLString = self.licenseURL?.absoluteString ?? fallbackLicenseURL
            guard let targetLicenseURL = URL(string: targetLicenseURLString) else {
                print("❌ Error on parsing license url!")
                loadingRequest.finishLoading()
                return
            }

            var urlRequest = URLRequest(url: targetLicenseURL)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = spcData
            urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if let token = self.normalizedFairPlayToken {
                urlRequest.setValue(token, forHTTPHeaderField: "nv-authorizations")
                urlRequest.setValue(token, forHTTPHeaderField: "x-vudrm-token")
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            request(urlRequest).validate().responseData { response in
                if let error = response.error {
                    print("❌ Error on fetching CKC! -> \(error.localizedDescription)")
                    loadingRequest.finishLoading()
                    return
                }
                
                if let data = response.value {
                    if let ckcData = extractCkcData(from: data) {
                        print("✅ CKC fetched successfully!")
                        dataRequest.respond(with: ckcData)
                    } else {
                        print("❌ Error on parsing CKC response!")
                    }
                } else {
                    print("❌ Error in CKC data!")
                }
                loadingRequest.finishLoading()
            }
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
        return nil
    }

    if
        let jsonObject = try? JSONSerialization.jsonObject(with: responseData, options: []),
        let json = jsonObject as? [String: Any] {
        let supportedKeys = ["certificate", "Certificate", "cert", "CertMessage", "CertificateMessage"]
        for key in supportedKeys {
            if let certValue = json[key] as? String,
               let certData = Data(base64Encoded: certValue, options: [.ignoreUnknownCharacters]) {
                return certData
            }
        }
    }

    if
        let responseString = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        let base64Data = Data(base64Encoded: responseString, options: [.ignoreUnknownCharacters]),
        !base64Data.isEmpty {
        return base64Data
    }

    return responseData
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
