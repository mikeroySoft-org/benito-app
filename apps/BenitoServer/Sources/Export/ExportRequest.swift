import Foundation

/// One family's events to export, optionally narrowed to a child and a span of time.
struct ExportRequest: Sendable, Equatable {
    var familyID: String
    /// `nil` exports every child in the family.
    var childID: String?
    /// Inclusive, on the time an event started.
    var from: Date?
    /// Exclusive.
    var to: Date?
}
