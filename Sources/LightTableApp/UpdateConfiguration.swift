import Foundation

/// Development builds deliberately do not replace themselves with a GitHub release.
enum UpdateConfiguration: Equatable {
    case development
    case ready
    case invalid

    static let feedURL = "https://github.com/fuyuan9972-svg/LightTable/releases/latest/download/appcast.xml"

    static func read(_ info: [String: Any], isApplication: Bool) -> Self {
        guard isApplication, info["LTDistribution"] as? String == "public" else { return .development }
        guard info["SUFeedURL"] as? String == feedURL,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUAllowsAutomaticUpdates"] as? Bool == false else { return .invalid }
        return .ready
    }
}
