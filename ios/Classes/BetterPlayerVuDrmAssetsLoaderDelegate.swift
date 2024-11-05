import UIKit
import AVFoundation
import Alamofire

@objc public class BetterPlayerVuDrmAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    var certificateURL: String?
    var licenseURL: URL?
    var fairPlayToken: String?

    //licenseURL currently not used
    @objc public init(certificateURL: String? = nil, licenseURL: URL? = nil, fairPlayToken: String? = nil) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        self.fairPlayToken = fairPlayToken
        super.init()
    }
    
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        let url = self.certificateURL ?? ""
        let headers: HTTPHeaders? = ["x-vudrm-token" : self.fairPlayToken ?? ""]
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
            let certificateData = response.value
            
            guard let licenseUrl = loadingRequest.request.url else {
                loadingRequest.finishLoading()
                print("❌ Error on extracting license url!")
                return
            }
            print("✅ License url validation passed: -> \(licenseUrl)")
            
            // create SPC Message
            let contentId = licenseUrl.lastPathComponent
            guard
                let certificateData = certificateData,
                let contentIdData = contentId.data(using: .utf8),
                let spcData = try? loadingRequest.streamingContentKeyRequestData(forApp: certificateData, contentIdentifier: contentIdData, options: nil),
                let dataRequest = loadingRequest.dataRequest else {
                    loadingRequest.finishLoading()
                    print("❌ Error on creating SPC Message!")
                    return
            }
            
            // get CKC
            let url = licenseUrl.absoluteString.replacingOccurrences(of: "skd", with: "https")
            let spcBase64EncodedData = spcData.base64EncodedData(options: Data.Base64EncodingOptions(rawValue: 0))
            let spcBase64EncodedString = String(data: spcBase64EncodedData, encoding: .utf8) ?? ""
            let parameters = ["token" : self.fairPlayToken, "contentId" : contentId, "payload" : spcBase64EncodedString]
            let encoding = jsonString(from: parameters) ?? ""
            let headers: HTTPHeaders? = [ "Content-Type" : "application/json"]
            request(url, method: .post, encoding: encoding, headers: headers).validate().responseData { response in
                if let error = response.error {
                    print("❌ Error on fetching CKC! -> \(error.localizedDescription)")
                    loadingRequest.finishLoading()
                    return
                }
                
                if let data = response.value {
                    print("✅ CKC fetched successfully!")
                    dataRequest.respond(with: data)
                } else {
                    print("❌ Error in CKC data!")
                }
                loadingRequest.finishLoading()
            }
        }
        
        return true
    }
}

func jsonString(from object: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

extension String: ParameterEncoding {
    public func encode(_ urlRequest: URLRequestConvertible, with parameters: Parameters?) throws -> URLRequest {
        var request = try urlRequest.asURLRequest()
        request.httpBody = data(using: .utf8, allowLossyConversion: true)
        return request
    }
}
