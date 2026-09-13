import Network
import Observation

@MainActor @Observable
final class NetworkPolicy {
    private(set) var isWiFi = false
    private(set) var isConnected = false
    var onRestrictedPath: (() -> Void)?
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                self.isWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi) && !path.isExpensive
                if !self.isWiFi { self.onRestrictedPath?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Curator.network"))
    }
    func permitsDownload(allowCellular: Bool) -> Bool { isWiFi || (allowCellular && isConnected) }
}
