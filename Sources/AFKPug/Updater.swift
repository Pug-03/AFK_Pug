import AppKit
import CryptoKit
import Foundation

struct AvailableUpdate: Equatable {
    let version: String
    let page: URL
    /// nil: this release has no app to install in place, so "Update" opens the page.
    let zip: URL?
    let sha256: String?
}

/// Finds and installs new versions from this repository's GitHub releases. The
/// check sends nothing about the user: it's one anonymous GET, once a day at most.
enum Updater {
    static let checkEvery: TimeInterval = 24 * 3600
    private static let latest = URL(string: "https://api.github.com/repos/Pug-03/AFK_Pug/releases/latest")!
    private static let zipName = "AFK-Pug.zip"
    private static let downloadPrefix = "/Pug-03/AFK_Pug/releases/download/"
    private static let appName = "AFK Pug.app"
    private static let bundleID = "com.pug03.afkpug"

    enum Failure: Error, Equatable { case download, checksum, unpack, notOurApp, wrongVersion, badSignature, cantLaunch }

    static var currentVersion: String {
        Sim.value("app-version") ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Where the running app lives, if an in-place update can replace it.
    static var installTarget: URL? {
        let target = Sim.enabled ? Sim.dir.appendingPathComponent("Applications/\(appName)") : URL(fileURLWithPath: "/Applications/\(appName)")
        if !Sim.enabled, Bundle.main.bundleURL.standardizedFileURL.path != target.path { return nil }
        return FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) ? target : nil
    }

    /// True if `candidate` is a higher dotted version than `current`. Unreadable versions never are.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let digits = text.hasPrefix("v") ? String(text.dropFirst()) : text
            let values = digits.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return values.isEmpty || values.contains(where: { $0 == nil || $0! < 0 }) ? nil : values.compactMap { $0 }
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }

    /// Reads a GitHub release. A download link outside this repository's releases is ignored.
    static func parse(_ data: Data) -> AvailableUpdate? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let pageText = json["html_url"] as? String, let page = URL(string: pageText),
              page.scheme == "https", page.host == "github.com" else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let asset = (json["assets"] as? [[String: Any]])?.first { $0["name"] as? String == zipName }
        let zip = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix(downloadPrefix) ? url : nil
        }
        var sha: String?
        if let digest = asset?["digest"] as? String, digest.hasPrefix("sha256:") { sha = String(digest.dropFirst(7)).lowercased() }
        return AvailableUpdate(version: version, page: page, zip: zip, sha256: sha)
    }

    /// Fetches the latest release; `done` runs on the main thread. nil: couldn't tell.
    static func fetchLatest(_ done: @escaping @MainActor @Sendable (AvailableUpdate?) -> Void) {
        if Sim.enabled {
            let update = Sim.value("latest-release").flatMap { parse(Data($0.utf8)) }
            MainActor.assumeIsolated { done(update) }
            return
        }
        var request = URLRequest(url: latest)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AFK-Pug/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let update = ok ? data.flatMap(parse) : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { done(update) } }
        }.resume()
    }

    /// Downloads the zip to a temporary file.
    static func download(_ update: AvailableUpdate, _ done: @escaping @Sendable (Result<URL, Failure>) -> Void) {
        if let fake = Sim.value("update-zip") { done(.success(URL(fileURLWithPath: fake))); return }
        guard !Sim.enabled, let zip = update.zip else { done(.failure(.download)); return }
        var request = URLRequest(url: zip)
        request.timeoutInterval = 120
        URLSession.shared.downloadTask(with: request) { file, response, _ in
            guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else { done(.failure(.download)); return }
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("afkpug-\(UUID().uuidString).zip")
            do { try FileManager.default.moveItem(at: file, to: kept); done(.success(kept)) } catch { done(.failure(.download)) }
        }.resume()
    }

    /// Unpacks the zip and checks it really is this app at the promised version.
    /// Returns the checked app, in a temporary folder.
    static func prepare(zip: URL, for update: AvailableUpdate) -> Result<URL, Failure> {
        if let expected = update.sha256 {
            guard let data = try? Data(contentsOf: zip) else { return .failure(.checksum) }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { return .failure(.checksum) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("afkpug-update-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) else { return .failure(.unpack) }
        let app = folder.appendingPathComponent(appName)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else { return .failure(.notOurApp) }
        guard info["CFBundleShortVersionString"] as? String == update.version else { return .failure(.wrongVersion) }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { return .failure(.badSignature) }
        return .success(app)
    }

    /// Replaces the app once `pid` has quit, then opens it. If the copy fails the old
    /// app is put back; if the app doesn't quit, nothing is touched.
    static let swapScript = """
    pid=$1; new=$2; target=$3
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
    kill -0 "$pid" 2>/dev/null && exit 1
    old="$target.previous.$$"
    mv "$target" "$old" || exit 1
    if /usr/bin/ditto "$new" "$target"; then rm -rf "$old"; else rm -rf "$target"; mv "$old" "$target"; fi
    rm -rf "$(dirname "$new")"
    [ -n "$AFKPUG_SIM" ] || /usr/bin/open "$target"
    """

    /// Starts the swap in its own session, so it outlives this process.
    static func launchSwap(app: URL, target: URL, waitingFor pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh -c \"$0\" swap \"$1\" \"$2\" \"$3\" >/dev/null 2>&1 &",
                             swapScript, String(pid), app.path, target.path]
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }

    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }
}

extension Updater.Failure {
    var message: String {
        switch self {
        case .download: return tr("Couldn't download the update.")
        case .checksum, .unpack, .notOurApp, .wrongVersion, .badSignature:
            return tr("The downloaded update failed its safety check, so it wasn't installed.")
        case .cantLaunch: return tr("Couldn't start the update.")
        }
    }
}
