import Foundation

public enum CodexRemoteTunnelPathProbePolicy {
    public static func shouldProbe(
        status: SSHTunnelStatus?,
        lastProbeAt: Date?,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let status,
              status.state == .running else {
            return false
        }
        guard let lastProbeAt else {
            return true
        }
        return now.timeIntervalSince(lastProbeAt) >= max(0, minimumInterval)
    }
}
