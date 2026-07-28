import Cocoa
import os

struct Release {
    let version: String
    let zipURL: URL
    let notes: String
}

/// Checks GitHub Releases, downloads a new build, and swaps it in.
///
/// The security-critical part is `verifyMatchesRunningApp`. A downloaded bundle is
/// executable code from the network; before anything is installed it must satisfy the
/// *running* app's designated requirement — same bundle identifier, same signing
/// certificate. A tampered download, a hijacked release asset, or a MITM all fail that
/// check and are discarded.
final class Updater {
    static let shared = Updater()

    static let repository = "indincys/hyperkey"

    private let log = Logger(subsystem: Hyper.subsystem, category: "updater")
    private var isBusy = false

    enum CheckResult {
        case upToDate
        case available(Release)
        case failed(String)
    }

    // MARK: - Check

    func check(completion: @escaping (CheckResult) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hyper/\(Hyper.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        // Always ask the origin: a cached 304 would silently hide a new release.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let result = self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func parse(data: Data?, response: URLResponse?, error: Error?) -> CheckResult {
        if let error {
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 403 here is almost always GitHub's unauthenticated rate limit.
            let hint = http.statusCode == 403 ? "请求过于频繁，请稍后再试" : "服务器返回 \(http.statusCode)"
            return .failed(hint)
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .failed("无法解析发布信息") }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isVersion(version, newerThan: Hyper.version) else { return .upToDate }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let zipURL = URL(string: urlString)
        else { return .failed("这个版本没有提供可下载的压缩包") }

        let notes = (json["body"] as? String) ?? ""
        log.info("update available: \(version, privacy: .public)")
        return .available(Release(version: version, zipURL: zipURL, notes: notes))
    }

    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Download and install

    /// Downloads, verifies, and stages the update, then replaces this app and relaunches.
    /// On success this call does not return normally — the process is terminated.
    func downloadAndInstall(_ release: Release, completion: @escaping (String?) -> Void) {
        guard !isBusy else { return }
        isBusy = true

        URLSession.shared.downloadTask(with: release.zipURL) { [weak self] location, response, error in
            guard let self else { return }
            let finish: (String?) -> Void = { message in
                DispatchQueue.main.async {
                    self.isBusy = false
                    completion(message)
                }
            }

            if let error { return finish("下载失败：\(error.localizedDescription)") }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return finish("下载失败：服务器返回 \(http.statusCode)")
            }
            guard let location else { return finish("下载失败：没有收到文件") }

            do {
                let staged = try self.stage(downloadedZip: location)
                try self.verifyMatchesRunningApp(staged)
                try self.scheduleSwap(stagedApp: staged)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                self.log.error("update install failed: \(error.localizedDescription, privacy: .public)")
                finish(error.localizedDescription)
            }
        }.resume()
    }

    private func stage(downloadedZip: URL) throws -> URL {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hyper-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let zip = workspace.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: downloadedZip, to: zip)

        let unpacked = workspace.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)

        // ditto preserves the bundle's symlinks and extended attributes; unzip does not,
        // and a mangled bundle would fail signature validation.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.message("解压失败") }

        let contents = try FileManager.default.contentsOfDirectory(
            at: unpacked, includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("压缩包里没有找到应用")
        }
        return app
    }

    /// The gate between "downloaded bytes" and "code we are willing to run".
    private func verifyMatchesRunningApp(_ candidate: URL) throws {
        var runningCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &runningCode) == errSecSuccess,
              let runningCode
        else { throw UpdateError.message("无法读取当前应用的签名") }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(runningCode, [], &requirement) == errSecSuccess,
              let requirement
        else { throw UpdateError.message("无法读取当前应用的签名要求") }

        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode
        else { throw UpdateError.message("下载的应用没有有效签名") }

        let status = SecStaticCodeCheckValidity(candidateCode, [], requirement)
        guard status == errSecSuccess else {
            log.error("downloaded bundle failed signature check: OSStatus \(status)")
            throw UpdateError.message(
                "下载的版本签名与当前版本不匹配，已丢弃。\n为安全起见没有安装，请从 GitHub 手动下载。"
            )
        }
        log.info("downloaded bundle satisfies the running app's designated requirement")
    }

    /// Hands the swap to a detached script: a process cannot replace its own bundle
    /// while running, so the script waits for us to exit first.
    private func scheduleSwap(stagedApp: URL) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            throw UpdateError.message("当前不是从应用包运行，无法自动更新")
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.message("没有写入 \(target.deletingLastPathComponent().path) 的权限")
        }

        let script = stagedApp.deletingLastPathComponent()
            .appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        # 等当前进程退出后再替换，避免自己删自己
        for _ in $(seq 1 100); do
            kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
            sleep 0.1
        done
        NEW=\(shellQuote(stagedApp.path))
        OLD=\(shellQuote(target.path))
        WORK=\(shellQuote(stagedApp.deletingLastPathComponent().deletingLastPathComponent().path))

        # 绝不让用户落到「没有应用」的状态：先把旧版挪开而不是删掉，
        # 新版就位后才清理；中途任何一步失败都回滚到旧版并照常启动。
        if [ -d "$NEW" ]; then
            BACKUP="$OLD.replacing-$$"
            if mv "$OLD" "$BACKUP" 2>/dev/null; then
                if mv "$NEW" "$OLD" 2>/dev/null; then
                    rm -rf "$BACKUP"
                else
                    mv "$BACKUP" "$OLD"
                fi
            fi
            open "$OLD"
        fi
        rm -rf "$WORK"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        try task.run()
        log.info("swap scheduled; terminating for update")
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }
}
