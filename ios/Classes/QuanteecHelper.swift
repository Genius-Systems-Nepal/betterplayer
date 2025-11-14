import Foundation
import AVKit
// import QuanteecCore
// import QuanteecPluginAVPlayer

@objc public class QuanteecHelper: NSObject {

//     private static var plugin: QuanteecPlugin?
    
    @objc public static func setup(player: AVPlayer, dictQuanteecConfig: [String: Any]) {
        
        guard let key = dictQuanteecConfig["qunateecKey"] as? String, let videoId = dictQuanteecConfig["videoId"] as? String else {
//             print("quanteec === key not found")
            return
        }
        
//         print("quanteec === key = \(key) videoId = \(videoId)")
        
//         QuanteecConfig.configure(quanteecKey: key)
//         QuanteecConfig.shared.videoID = videoId
//         QuanteecHelper.plugin = QuanteecPlugin(player: player)
    }
}
