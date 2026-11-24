import Foundation

enum MainPane: String, CaseIterable, Identifiable, Sendable {
    case overview
    case people
    case connections
    case backups
    case export
    case reliability
    case logs

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .people: "People & Devices"
        case .connections: "Connections"
        case .backups: "Backups"
        case .export: "Export"
        case .reliability: "Reliability"
        case .logs: "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .people: "person.2"
        case .connections: "network"
        case .backups: "externaldrive.badge.timemachine"
        case .export: "square.and.arrow.up"
        case .reliability: "checkmark.shield"
        case .logs: "text.alignleft"
        }
    }
}
