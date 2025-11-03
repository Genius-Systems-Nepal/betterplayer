import Foundation
import AVKit
import QuanteecCore
import QuanteecPluginAVPlayer

import Foundation
import AVKit
import QuanteecCore
import QuanteecPluginAVPlayer

@objc public class QuanteecHelper: NSObject {

    @objc public static func setup(player: AVPlayer, videoID: String) {
        QuanteecConfig.configure(quanteecKey: "10a09cc682df4918a6f2c0edf1ba165a")
        QuanteecConfig.shared.videoID = videoID

        shared.setupPlugin(for: player)
    }
    
    @objc public static func clean() {
        shared.player = nil
        shared.plugin?.cleanup()
        shared.plugin = nil
    }

    private static let shared = QuanteecHelper()

    private weak var player: AVPlayer?
    private var plugin: QuanteecPlugin?

    private func setupPlugin(for player: AVPlayer) {
        self.player = player
        plugin = QuanteecPlugin(player: player)
    }
}

