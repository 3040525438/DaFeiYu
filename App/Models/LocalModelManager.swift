import Foundation
import Network
import DFCore
import DFAI

/// 用 `NWPathMonitor` 判断当前是否 Wi-Fi（D60：大模型默认只允许 Wi-Fi 下载）。
final class WiFiOnlyNetworkGate: LocalModelNetworkGating, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dafeiyu.local-model.network")
    private let lock = NSLock()
    private var wifiConfirmed = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            self.lock.lock()
            self.wifiConfirmed = isWiFi
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func isWiFi() async -> Bool {
        lock.lock()
        let confirmed = wifiConfirmed
        lock.unlock()
        if confirmed { return true }
        // 首次回调尚未到达时用当前路径兜底，避免把 Wi-Fi 误判成蜂窝网络
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }
}

/// 本地模型的界面状态：登记、下载/续传、校验、删除文件（W5 / D58–D61）。
///
/// 边界：
/// - 只负责文件与状态机，不做推理（推理内核见 N-18，仍未接入）；
/// - 下载进度以数据库为准，界面按固定间隔刷新，避免持有下载器内部状态；
/// - 任何错误只展示，不吞掉也不抛出给上层页面。
@MainActor
final class LocalModelManager: ObservableObject {
    @Published private(set) var models: [LocalModelRecord] = []
    @Published private(set) var workingIDs: Set<String> = []
    @Published private(set) var readyBytes: Int64 = 0
    @Published var message: String?

    private var repository: LocalModelRepository?
    private var downloader: LocalModelDownloader?

    var isReady: Bool { repository != nil && downloader != nil }

    func attach(repository: LocalModelRepository, downloader: LocalModelDownloader) {
        self.repository = repository
        self.downloader = downloader
    }

    func reload() async {
        guard let repository else { return }
        do {
            models = try await repository.all()
            readyBytes = try await repository.totalBytes()
        } catch {
            message = "读取本地模型失败：\(error.localizedDescription)"
        }
    }

    /// 新增登记。返回是否成功，供编辑器决定是否关闭。
    @discardableResult
    func register(_ record: LocalModelRecord) async -> Bool {
        guard let repository else { return false }
        do {
            _ = try await repository.save(record)
            await reload()
            message = "已登记「\(record.name)」，可以开始下载"
            return true
        } catch {
            message = "登记失败：\(describe(error))"
            return false
        }
    }

    func download(id: String) async {
        guard let downloader else { return }
        guard !workingIDs.contains(id) else { return }
        workingIDs.insert(id)
        defer { workingIDs.remove(id) }

        // 下载器每 2MB 落一次库，界面按 0.8s 刷新即可看到进度
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await self?.reload()
            }
        }
        defer { poller.cancel() }

        message = nil
        do {
            _ = try await downloader.download(id: id)
            message = "下载完成，校验和一致"
        } catch {
            message = "下载失败：\(describe(error))"
        }
        await reload()
    }

    func verify(id: String) async {
        guard let downloader else { return }
        workingIDs.insert(id)
        defer { workingIDs.remove(id) }
        do {
            _ = try await downloader.verify(id: id)
            message = "校验通过"
        } catch {
            message = "校验失败：\(describe(error))"
        }
        await reload()
    }

    /// 只删文件，保留登记记录（下次可重新下载）。
    func removeFile(id: String) async {
        guard let downloader else { return }
        do {
            try await downloader.removeDownload(id: id)
            message = "已删除本地文件"
        } catch {
            message = "删除文件失败：\(describe(error))"
        }
        await reload()
    }

    /// 删除登记记录（不触碰已下载文件，由界面先提示调用 `removeFile`）。
    func deleteRecord(id: String) async {
        guard let repository else { return }
        do {
            try await repository.delete(id: id)
            await reload()
            message = "已删除登记"
        } catch {
            message = "删除登记失败：\(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        if let downloadError = error as? LocalModelDownloadError {
            return downloadError.description
        }
        return error.localizedDescription
    }
}
