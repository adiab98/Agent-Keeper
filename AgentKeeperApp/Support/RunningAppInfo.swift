import Foundation
import Security

struct RunningAppInfo {
    let bundleURL: URL
    let bundleIdentifier: String
    let version: String
    let build: String
    let modifiedAt: Date?
    let signingSummary: String

    static var current: RunningAppInfo {
        let bundle = Bundle.main
        let bundleURL = bundle.bundleURL
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        let bundleIdentifier = bundle.bundleIdentifier ?? "Unknown"
        let modifiedAt = try? bundleURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        return RunningAppInfo(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build,
            modifiedAt: modifiedAt,
            signingSummary: Self.signingSummary(for: bundleURL)
        )
    }

    private static func signingSummary(for bundleURL: URL) -> String {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return "Unknown (codesign \(createStatus))"
        }

        var infoRef: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoRef
        )
        guard copyStatus == errSecSuccess,
              let info = infoRef as? [CFString: Any] else {
            return "Unknown (codesign \(copyStatus))"
        }

        let flags = (info[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
        let adHocSignatureFlag: UInt32 = 0x0002
        let isAdHoc = (flags & adHocSignatureFlag) != 0
        let team = info[kSecCodeInfoTeamIdentifier] as? String

        if let team, !team.isEmpty {
            return "Signed by Team \(team)"
        }
        if isAdHoc {
            return "Ad-hoc signed"
        }
        return "Signed without Team ID"
    }
}
