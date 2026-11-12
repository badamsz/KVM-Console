import Foundation
import Observation
import KVMKit

/// Runs network discovery for the Find Devices window: Bonjour while the
/// window is open, plus an on-demand subnet scan and Tailscale check.
@MainActor
@Observable
final class DiscoveryModel {
    struct Progress: Equatable {
        var done: Int
        var total: Int
        var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
    }

    private(set) var results = DiscoveryResults()
    private(set) var subnets: [IPv4Subnet] = []
    private(set) var scanProgress: Progress?
    private(set) var tailscaleProgress: Progress?
    private(set) var hasScanned = false
    private(set) var hasCheckedTailscale = false
    private(set) var hasTailscaleToken = false
    var tailscaleError: String?

    @ObservationIgnored private var bonjourTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var tailscaleTask: Task<Void, Never>?
    @ObservationIgnored private let prober = FingerprintProber()
    @ObservationIgnored private let credentials: CredentialStore

    var isScanning: Bool { scanTask != nil }
    var isCheckingTailscale: Bool { tailscaleTask != nil }

    init(credentials: CredentialStore) {
        self.credentials = credentials
        hasTailscaleToken = credentials.password(for: TailscaleClient.credentialID) != nil
    }

    func start() {
        subnets = IPv4Subnet.local()
        guard bonjourTask == nil else { return }
        let stream = Discovery.bonjour(prober: prober)
        bonjourTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func stop() {
        bonjourTask?.cancel(); bonjourTask = nil
        stopScan()
        tailscaleTask?.cancel(); tailscaleTask = nil
        tailscaleProgress = nil
    }

    // MARK: Subnet scan

    func scan() {
        subnets = IPv4Subnet.local()
        guard scanTask == nil, !subnets.isEmpty else { return }
        hasScanned = true
        let stream = Discovery.scan(subnets, prober: prober)
        scanTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if case .progress(let done, let total) = event {
                    self.scanProgress = Progress(done: done, total: total)
                } else {
                    self.handle(event)
                }
            }
            // A stopped scan leaves the state to whoever stopped it.
            guard !Task.isCancelled else { return }
            self?.scanTask = nil
            self?.scanProgress = nil
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanProgress = nil
    }

    // MARK: Tailscale

    func saveTailscaleToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        credentials.setPassword(trimmed, for: TailscaleClient.credentialID)
        hasTailscaleToken = true
        checkTailscale()
    }

    func forgetTailscaleToken() {
        tailscaleTask?.cancel(); tailscaleTask = nil
        credentials.deletePassword(for: TailscaleClient.credentialID)
        hasTailscaleToken = false
        tailscaleError = nil
        tailscaleProgress = nil
    }

    func checkTailscale() {
        guard tailscaleTask == nil, let token = credentials.password(for: TailscaleClient.credentialID) else { return }
        tailscaleError = nil
        hasCheckedTailscale = true
        tailscaleProgress = Progress(done: 0, total: 0)
        let prober = prober
        tailscaleTask = Task { [weak self] in
            do {
                let peers = try await TailscaleClient(token: token).peers()
                for await event in Discovery.tailscale(peers, prober: prober) {
                    guard let self else { return }
                    if case .progress(let done, let total) = event {
                        self.tailscaleProgress = Progress(done: done, total: total)
                    } else {
                        self.handle(event)
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.tailscaleError = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.tailscaleTask = nil
            self?.tailscaleProgress = nil
        }
    }

    private func handle(_ event: DiscoveryEvent) {
        if case .found(let device) = event { results.add(device) }
    }
}
