import Foundation
import Sparkle

@main struct UpdateChecks {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: Bool, _ description: String) {
            precondition(value, description)
            count += 1
            print("PASS \(description)")
        }
        let configURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: configURL), format: nil) as! [String: Any]
        check(UpdateConfiguration.read(info, isApplication: true) == .ready, "public release starts update checks")
        check(UpdateConfiguration.read(info, isApplication: false) == .development, "command-line development run cannot update itself")
        check(UpdateConfiguration.read([:], isApplication: true) == .development, "unconfigured development app cannot update itself")
        var local = info
        local["LTDistribution"] = "development"
        check(UpdateConfiguration.read(local, isApplication: true) == .development, "local build cannot be replaced by a public release")
        for key in ["SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUAllowsAutomaticUpdates"] {
            var damaged = info
            damaged.removeValue(forKey: key)
            check(UpdateConfiguration.read(damaged, isApplication: true) == .invalid, "missing \(key) fails closed")
        }
        for value in ["http://github.com/unsafe.xml", "https://example.com/unsafe.xml"] {
            var damaged = info; damaged["SUFeedURL"] = value
            check(UpdateConfiguration.read(damaged, isApplication: true) == .invalid, "unexpected update host is rejected")
        }
        for value in ["", "not-a-key", Data(repeating: 1, count: 31).base64EncodedString()] {
            var damaged = info; damaged["SUPublicEDKey"] = value
            check(UpdateConfiguration.read(damaged, isApplication: true) == .invalid, "malformed signing key is rejected")
        }
        var silentInstall = info; silentInstall["SUAllowsAutomaticUpdates"] = true
        check(UpdateConfiguration.read(silentInstall, isApplication: true) == .invalid, "installation must follow an explicit user action")
        let comparator = SUStandardVersionComparator.default
        check(comparator.compareVersion("0.1.68", toVersion: "0.1.69") == .orderedAscending, "new release is an upgrade")
        check(comparator.compareVersion("0.1.69", toVersion: "0.1.69") == .orderedSame, "same version is not an update")
        check(comparator.compareVersion("0.1.69", toVersion: "0.1.65") == .orderedDescending, "older GitHub release is not an update")
        check(comparator.compareVersion("0.1.9", toVersion: "0.1.10") == .orderedAscending, "numeric version comparison handles digit boundaries")
        check(info["SUEnableAutomaticChecks"] as? Bool == true, "automatic checks are enabled by default")
        check(info["SUAutomaticallyUpdate"] as? Bool == false, "downloads are not started silently")
        print("\(count) update checks passed")
    }
}
