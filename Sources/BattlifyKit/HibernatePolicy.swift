import Foundation

/// Decides when a closed Mac should switch from ordinary sleep to hibernation.
///
/// A sleeping Apple silicon Mac still draws around 130 mW, almost all of it memory
/// sitting in self-refresh. Nothing running on the machine can reduce that — the
/// only lever is `hibernatemode 25`, which writes memory to disk and cuts the rail.
/// Measured over a nine-hour night that is the difference between 2% and nothing.
///
/// Leaving hibernation on permanently is the wrong trade, though: every lid close
/// then costs a multi-second wake, including the ones where you are back in five
/// minutes. So wait first. Short closes never reach the delay and stay instant;
/// a Mac shut for the night crosses it and hibernates for the remainder.
///
/// The delay is measured from when the lid shut, not from when the daemon noticed.
/// While the Mac is asleep the daemon only runs during macOS's maintenance wakes,
/// which are roughly an hour apart, so the switch lands at the first wake past the
/// delay rather than exactly on it.
public enum HibernatePolicy {
    public enum Decision: Equatable {
        /// Leave `hibernatemode` alone.
        case hold
        /// Switch to hibernation for the rest of this sleep.
        case hibernate
        /// Put the user's own setting back — the lid opened, or power arrived.
        case restore
    }

    /// - Parameters:
    ///   - lidClosedSince: when the current lid-closed spell began, nil if open.
    ///   - applied: whether we have already switched this spell.
    public static func decide(config: BattlifyConfig,
                              onExternalPower: Bool,
                              lidClosedSince: Date?,
                              now: Date,
                              applied: Bool) -> Decision {
        // Turned off, or the user asked for permanent deep sleep and owns the setting.
        guard config.hibernateAfterMinutes > 0, config.sleepDepth != .deep else {
            return applied ? .restore : .hold
        }
        // Plugged in there is nothing to save, and an open lid means the spell is over.
        guard let since = lidClosedSince, !onExternalPower else {
            return applied ? .restore : .hold
        }
        if applied { return .hold }   // already hibernating for this spell
        let delay = Double(config.hibernateAfterMinutes) * 60
        return now.timeIntervalSince(since) >= delay ? .hibernate : .hold
    }
}
