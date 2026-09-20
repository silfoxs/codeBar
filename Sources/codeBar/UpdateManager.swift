import AppKit
import Combine
import Foundation

@MainActor
final class UpdateManager: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case updateAvailable
        case downloading
        case installing
        case upToDate
        case failed
    }

    struct Release: Identifiable, Sendable {
        let version: String
        let tagName: String
        let downloadURL: URL
        let expectedSHA256: String?

        var id: String { tagName }
    }

    private struct GitHubRelease: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let browserDownloadURL: URL
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case digest
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct PreparedUpdate: Sendable {
        let sourceAppURL: URL
        let destinationAppURL: URL
        let mountURL: URL
        let diskImageURL: URL
        let helperURL: URL
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var statusMessage: String?
    @Published var pendingRelease: Release?

    let currentVersion: String

    private let repository = "silfoxs/codebar"
    private var downloadingRelease: Release?
    private lazy var downloadSession = URLSession(
        configuration: .ephemeral,
        delegate: self,
        delegateQueue: nil
    )

    override init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "开发版本"
        super.init()
    }

    var isBusy: Bool {
        phase == .checking || phase == .downloading || phase == .installing
    }

    func checkForUpdates() async {
        guard !isBusy else { return }

        phase = .checking
        statusMessage = "正在检查更新…"
        pendingRelease = nil

        do {
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
            )
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("codeBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw UpdateError.githubStatus(httpResponse.statusCode)
            }

            let githubRelease = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVersion = Self.version(from: githubRelease.tagName)

            guard Self.isNewer(latestVersion, than: currentVersion) else {
                phase = .upToDate
                statusMessage = "当前已是最新版本"
                return
            }

            guard let asset = Self.preferredDiskImage(in: githubRelease.assets) else {
                throw UpdateError.missingInstaller
            }

            let release = Release(
                version: latestVersion,
                tagName: githubRelease.tagName,
                downloadURL: asset.browserDownloadURL,
                expectedSHA256: asset.digest?.replacingOccurrences(of: "sha256:", with: "")
            )
            phase = .updateAvailable
            statusMessage = "发现新版本 \(latestVersion)"
            pendingRelease = release
        } catch {
            fail(error)
        }
    }

    func downloadAndInstall(_ release: Release) {
        guard !isBusy else { return }

        pendingRelease = nil
        downloadingRelease = release
        downloadProgress = 0
        phase = .downloading
        statusMessage = "正在下载 codeBar \(release.version)…"

        var request = URLRequest(url: release.downloadURL)
        request.setValue("codeBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        downloadSession.downloadTask(with: request).resume()
    }

    private func finishDownload(at diskImageURL: URL) {
        guard let release = downloadingRelease else {
            try? FileManager.default.removeItem(at: diskImageURL)
            fail(UpdateError.invalidDownload)
            return
        }

        downloadingRelease = nil
        downloadProgress = 1
        phase = .installing
        statusMessage = "正在准备安装…"

        let destinationAppURL = Bundle.main.bundleURL
        let expectedBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.silfoxs.codeBar"

        guard destinationAppURL.pathExtension == "app" else {
            try? FileManager.default.removeItem(at: diskImageURL)
            fail(UpdateError.notRunningFromAppBundle)
            return
        }

        Task {
            do {
                let preparedUpdate = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareUpdate(
                        diskImageURL: diskImageURL,
                        destinationAppURL: destinationAppURL,
                        expectedBundleIdentifier: expectedBundleIdentifier,
                        expectedVersion: release.version,
                        expectedSHA256: release.expectedSHA256
                    )
                }.value

                do {
                    try Self.launchInstaller(preparedUpdate)
                } catch {
                    Self.cleanUp(preparedUpdate)
                    throw error
                }
                statusMessage = "即将重启并完成安装…"
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: diskImageURL)
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        phase = .failed
        statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        downloadingRelease = nil
    }

    nonisolated private static func prepareUpdate(
        diskImageURL: URL,
        destinationAppURL: URL,
        expectedBundleIdentifier: String,
        expectedVersion: String,
        expectedSHA256: String?
    ) throws -> PreparedUpdate {
        if let expectedSHA256 {
            let checksumOutput = try run(
                "/usr/bin/shasum",
                arguments: ["-a", "256", diskImageURL.path]
            )
            let actualSHA256 = String(data: checksumOutput, encoding: .utf8)?
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map(String.init)
            guard actualSHA256?.lowercased() == expectedSHA256.lowercased() else {
                throw UpdateError.checksumMismatch
            }
        }

        let mountURL = try mount(diskImageURL: diskImageURL)

        do {
            let sourceAppURL = mountURL.appendingPathComponent("codeBar.app", isDirectory: true)
            guard FileManager.default.fileExists(atPath: sourceAppURL.path) else {
                throw UpdateError.missingAppInInstaller
            }

            guard
                let bundle = Bundle(url: sourceAppURL),
                bundle.bundleIdentifier == expectedBundleIdentifier
            else {
                throw UpdateError.bundleIdentifierMismatch
            }

            let bundledVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard bundledVersion == expectedVersion else {
                throw UpdateError.versionMismatch
            }

            try verifyCodeSignature(of: sourceAppURL)

            let destinationDirectory = destinationAppURL.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: destinationDirectory.path) else {
                throw UpdateError.destinationNotWritable
            }

            let helperDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("codeBarUpdater-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: helperDirectory,
                withIntermediateDirectories: true
            )
            let helperURL = helperDirectory.appendingPathComponent("install-update.sh")
            try installerScript.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: helperURL.path
            )

            return PreparedUpdate(
                sourceAppURL: sourceAppURL,
                destinationAppURL: destinationAppURL,
                mountURL: mountURL,
                diskImageURL: diskImageURL,
                helperURL: helperURL
            )
        } catch {
            _ = try? run("/usr/bin/hdiutil", arguments: ["detach", mountURL.path, "-force"])
            throw error
        }
    }

    nonisolated private static func mount(diskImageURL: URL) throws -> URL {
        let output = try run(
            "/usr/bin/hdiutil",
            arguments: ["attach", diskImageURL.path, "-nobrowse", "-readonly", "-plist"]
        )
        guard
            let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw UpdateError.cannotMountInstaller
        }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    nonisolated private static func verifyCodeSignature(of appURL: URL) throws {
        _ = try run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
    }

    nonisolated private static func launchInstaller(_ update: PreparedUpdate) throws {
        let process = Process()
        process.executableURL = update.helperURL
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            update.sourceAppURL.path,
            update.destinationAppURL.path,
            update.mountURL.path,
            update.diskImageURL.path,
            update.helperURL.deletingLastPathComponent().path
        ]
        try process.run()
    }

    nonisolated private static func cleanUp(_ update: PreparedUpdate) {
        _ = try? run(
            "/usr/bin/hdiutil",
            arguments: ["detach", update.mountURL.path, "-force"]
        )
        try? FileManager.default.removeItem(at: update.helperURL.deletingLastPathComponent())
    }

    @discardableResult
    nonisolated private static func run(_ executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.commandFailed(message ?? executable)
        }
        return output
    }

    nonisolated private static func version(from tagName: String) -> String {
        guard let firstDigit = tagName.firstIndex(where: { $0.isNumber }) else {
            return tagName
        }
        return String(tagName[firstDigit...])
    }

    nonisolated private static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    nonisolated private static func preferredDiskImage(in assets: [GitHubRelease.Asset]) -> GitHubRelease.Asset? {
        let diskImages = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let architecture: String
#if arch(arm64)
        architecture = "arm64"
#elseif arch(x86_64)
        architecture = "x86_64"
#else
        architecture = ""
#endif
        if let universal = diskImages.first(where: { $0.name.lowercased().contains("universal") }) {
            return universal
        }
        if let native = diskImages.first(where: {
            !architecture.isEmpty && $0.name.lowercased().contains(architecture)
        }) {
            return native
        }
        guard diskImages.count == 1 else { return nil }
        let onlyAssetName = diskImages[0].name.lowercased()
        let namesAnArchitecture = onlyAssetName.contains("arm64") || onlyAssetName.contains("x86_64")
        return namesAnArchitecture ? nil : diskImages[0]
    }

    nonisolated private static let installerScript = """
    #!/bin/sh
    set -u

    pid="$1"
    source_app="$2"
    destination_app="$3"
    mount_point="$4"
    disk_image="$5"
    helper_directory="$6"
    backup_app="${destination_app}.update-backup"

    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.2
    done

    rm -rf "$backup_app"
    if ! mv "$destination_app" "$backup_app"; then
      hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
      rm -f "$disk_image"
      open -n "$destination_app"
      rm -rf "$helper_directory"
      exit 1
    fi

    if ditto "$source_app" "$destination_app"; then
      rm -rf "$backup_app"
      hdiutil detach "$mount_point" >/dev/null 2>&1 || hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
      rm -f "$disk_image"
      open -n "$destination_app"
      rm -rf "$helper_directory"
      exit 0
    fi

    rm -rf "$destination_app"
    mv "$backup_app" "$destination_app" || true
    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    rm -f "$disk_image"
    open -n "$destination_app"
    rm -rf "$helper_directory"
    exit 1
    """
}

extension UpdateManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        Task { @MainActor [weak self] in
            self?.downloadProgress = progress
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard
                let response = downloadTask.response as? HTTPURLResponse,
                (200..<300).contains(response.statusCode)
            else {
                throw UpdateError.invalidResponse
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("codeBar-Update-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor [weak self] in
                self?.finishDownload(at: destination)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.fail(error)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.fail(error)
        }
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case githubStatus(Int)
    case missingInstaller
    case invalidDownload
    case notRunningFromAppBundle
    case cannotMountInstaller
    case missingAppInInstaller
    case bundleIdentifierMismatch
    case versionMismatch
    case checksumMismatch
    case destinationNotWritable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub 返回了无效响应"
        case .githubStatus(let status):
            status == 404 ? "暂未找到已发布的版本" : "检查更新失败（GitHub HTTP \(status)）"
        case .missingInstaller:
            "最新版本没有适用于当前 Mac 的 DMG 安装包"
        case .invalidDownload:
            "下载状态无效，请重新检查更新"
        case .notRunningFromAppBundle:
            "请从 codeBar.app 启动后再更新"
        case .cannotMountInstaller:
            "无法打开下载的安装包"
        case .missingAppInInstaller:
            "安装包中没有找到 codeBar.app"
        case .bundleIdentifierMismatch:
            "安装包的应用标识不匹配"
        case .versionMismatch:
            "安装包版本与 GitHub Release 不匹配"
        case .checksumMismatch:
            "安装包校验失败，请重新下载"
        case .destinationNotWritable:
            "当前安装位置不可写，请确认当前用户有权限替换 codeBar.app"
        case .commandFailed(let message):
            "更新安装失败：\(message)"
        }
    }
}
