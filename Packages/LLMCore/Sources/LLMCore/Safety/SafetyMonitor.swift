import Foundation
import Observation

/// Thermal state as an ordered level.
public enum ThermalLevel: Int, Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        }
    }

    /// Localized short label for the UI.
    public var localizedName: String {
        switch self {
        case .nominal: String(localized: "Normal", bundle: .module)
        case .fair: String(localized: "Warm", bundle: .module)
        case .serious: String(localized: "Hot", bundle: .module)
        case .critical: String(localized: "Too hot", bundle: .module)
        }
    }
}

/// Observes the device's thermal state.
///
/// - At ``ThermalLevel/serious`` ``isThermalWarning`` turns on (the UI should warn).
/// - At ``ThermalLevel/critical`` ``isGenerationBlocked`` turns on: ``ChatViewModel`` stops the
///   running reply and refuses new ones until the level drops below critical.
///
/// Memory warnings and app lifecycle are UIKit/SwiftUI events; the app forwards them to
/// ``ChatViewModel/handleMemoryWarning()`` and ``ChatViewModel/handleLifecycle(_:)``.
@Observable
@MainActor
public final class SafetyMonitor {
    public private(set) var thermalLevel: ThermalLevel

    /// Called on every level change (after ``thermalLevel`` is updated).
    @ObservationIgnored public var onThermalLevelChange: ((ThermalLevel) -> Void)?

    @ObservationIgnored private let readThermalState: @Sendable () -> ProcessInfo.ThermalState
    @ObservationIgnored nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - readThermalState: injectable for tests.
    ///   - observeSystemNotifications: subscribe to `thermalStateDidChangeNotification`.
    public init(
        readThermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        observeSystemNotifications: Bool = true
    ) {
        self.readThermalState = readThermalState
        self.thermalLevel = ThermalLevel(readThermalState())
        if observeSystemNotifications {
            observer = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The UI should show a "device is hot" warning.
    public var isThermalWarning: Bool { thermalLevel >= .serious }

    /// New generations are refused (and a running one is stopped).
    public var isGenerationBlocked: Bool { thermalLevel >= .critical }

    /// Re-reads the thermal state.
    public func refresh() {
        update(ThermalLevel(readThermalState()))
    }

    /// Applies a level (also used by tests and the self-test harness to simulate heat).
    public func update(_ level: ThermalLevel) {
        guard level != thermalLevel else { return }
        thermalLevel = level
        onThermalLevelChange?(level)
    }
}
