import Foundation

enum CategoryClassifier {
    private static let browserBundles: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "app.zen-browser.zen", // Zen
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.sigmaos.sigmaos.macos",
        "com.kagi.kagimacOS", // Orion
    ]

    private static let codingBundles: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "com.github.atom",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.jetbrains.AppCode",
        "com.jetbrains.WebStorm",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.pycharm",
        "com.jetbrains.CLion",
        "com.jetbrains.goland",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "com.panic.Nova",
        "com.panic.Transmit",
        "com.figma.Desktop",
    ]

    private static let communicationBundles: Set<String> = [
        "com.apple.MobileSMS",
        "com.apple.mail",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "us.zoom.xos",
        "com.apple.FaceTime",
        "net.whatsapp.WhatsApp",
        "com.tencent.xinWeChat",
        "ru.keepcoder.Telegram",
        "com.facebook.archon",
        "com.linear",
        "com.notion.id",
        "com.readdle.smartemail-Mac", // Spark
        "com.superhuman.mail",
    ]

    private static let designBundles: Set<String> = [
        "com.figma.Desktop",
        "com.bohemiancoding.sketch3",
        "com.adobe.Photoshop",
        "com.adobe.Illustrator",
        "com.adobe.Acrobat.Pro",
        "com.adobe.LightroomClassicCC7",
        "com.pixelmatorteam.pixelmator.x",
        "com.apple.Freeform",
        "com.framer.desktop",
        "com.canva.CanvaDesktop",
    ]

    private static let mediaBundles: Set<String> = [
        "com.apple.Music",
        "com.apple.TV",
        "com.spotify.client",
        "com.apple.QuickTimePlayerX",
        "com.colliderli.iina",
        "org.videolan.vlc",
        "com.apple.photoanalysisd",
        "com.apple.Photos",
        "com.apple.iMovieApp",
        "com.apple.FinalCut",
    ]

    private static let productivityBundles: Set<String> = [
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.apple.Notes",
        "com.apple.reminders",
        "com.apple.iCal",
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.microsoft.Outlook",
        "md.obsidian",
        "com.culturedcode.ThingsMac",
        "com.todoist.mac.Todoist",
        "com.omnigroup.OmniFocus3",
        "com.omnigroup.OmniFocus4",
        "com.apple.dt.Instruments",
        "com.raycast.macos",
        "com.apple.finder",
    ]

    private static let entertainmentBundles: Set<String> = [
        "com.apple.AppStore",
        "com.valvesoftware.steam",
        "com.twitch.desktop",
        "tv.twitch",
        "com.netflix.Netflix",
    ]

    private static let learningDomains: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "coursera.org",
        "www.coursera.org",
        "udemy.com",
        "www.udemy.com",
        "edx.org",
        "www.edx.org",
        "khanacademy.org",
        "www.khanacademy.org",
        "docs.python.org",
        "developer.apple.com",
        "swift.org",
        "stackoverflow.com",
        "www.stackoverflow.com",
        "github.com",
        "www.github.com",
        "medium.com",
        "dev.to",
        "css-tricks.com",
        "mdn.io",
        "developer.mozilla.org",
        "wikipedia.org",
        "en.wikipedia.org",
        "arxiv.org",
        "news.ycombinator.com",
        "leetcode.com",
        "www.leetcode.com",
    ]

    private static let entertainmentDomains: Set<String> = [
        "twitter.com",
        "x.com",
        "www.twitter.com",
        "reddit.com",
        "www.reddit.com",
        "instagram.com",
        "www.instagram.com",
        "tiktok.com",
        "www.tiktok.com",
        "netflix.com",
        "www.netflix.com",
        "twitch.tv",
        "www.twitch.tv",
        "facebook.com",
        "www.facebook.com",
    ]

    static func isBrowser(bundleIdentifier: String) -> Bool {
        browserBundles.contains(bundleIdentifier)
    }

    static func classify(
        bundleIdentifier: String,
        appName: String,
        domain: String?
    ) -> ActivityCategory {
        if let domain {
            let host = domain.lowercased()
            if learningDomains.contains(host) || learningDomains.contains(stripWWW(host)) {
                return .learning
            }
            if entertainmentDomains.contains(host) || entertainmentDomains.contains(stripWWW(host)) {
                return .entertainment
            }
            if isBrowser(bundleIdentifier: bundleIdentifier) {
                return .browsing
            }
        }

        if codingBundles.contains(bundleIdentifier) { return .coding }
        if designBundles.contains(bundleIdentifier) { return .design }
        if communicationBundles.contains(bundleIdentifier) { return .communication }
        if mediaBundles.contains(bundleIdentifier) { return .media }
        if productivityBundles.contains(bundleIdentifier) { return .productivity }
        if entertainmentBundles.contains(bundleIdentifier) { return .entertainment }
        if isBrowser(bundleIdentifier: bundleIdentifier) { return .browsing }

        let lowered = appName.lowercased()
        if lowered.contains("code") || lowered.contains("terminal") || lowered.contains("xcode") {
            return .coding
        }
        if lowered.contains("slack") || lowered.contains("mail") || lowered.contains("message") {
            return .communication
        }

        if bundleIdentifier.hasPrefix("com.apple.") {
            return .system
        }

        return .other
    }

    private static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func domain(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
            return host.lowercased()
        }
        // Bare host pasted without scheme
        if !urlString.contains(" "), urlString.contains(".") {
            return urlString
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .split(separator: "/")
                .first
                .map(String.init)?
                .lowercased()
        }
        return nil
    }
}
