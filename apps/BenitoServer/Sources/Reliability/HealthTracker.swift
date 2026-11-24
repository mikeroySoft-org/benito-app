import Foundation

/// Remembers which problems are ongoing, so each is announced once when it starts and can be
/// announced again only after it has gone away.
struct HealthTracker: Equatable, Sendable {
    private(set) var active: Set<HealthCondition> = []

    /// `observed` holds only the conditions that could be judged this time; one that is missing
    /// stays as it was. Returns the conditions that just started.
    mutating func update(_ observed: [HealthCondition: Bool]) -> [HealthCondition] {
        var started: [HealthCondition] = []
        for condition in HealthCondition.allCases {
            guard let isPresent = observed[condition] else { continue }
            if !isPresent {
                active.remove(condition)
            } else if active.insert(condition).inserted {
                started.append(condition)
            }
        }
        return started
    }
}
