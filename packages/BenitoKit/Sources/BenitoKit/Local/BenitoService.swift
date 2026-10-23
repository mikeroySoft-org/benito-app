import Foundation

/// The data calls the app and its intents make, whether a family server answers them
/// (`APIClient`) or this device does (`LocalBenitoService`). Errors follow the server:
/// `APIClientError.httpStatus` with the same status codes.
public protocol BenitoService: Sendable {
    func me() async throws -> MeResponseDTO
    func state(childId: UUID) async throws -> BabyStateDTO

    func createEvent(_ request: CreateEventRequestDTO) async throws -> EventDTO
    func updateEvent(id: UUID, _ changes: UpdateEventRequestDTO) async throws -> EventDTO
    func deleteEvent(id: UUID) async throws

    func startTimer(childId: UUID, kind: String, side: String?, at: Date) async throws -> TimerDTO
    func stopTimer(id: UUID, at: Date) async throws -> TimerDTO
    func pauseTimer(id: UUID, at: Date) async throws -> TimerDTO
    func resumeTimer(id: UUID, at: Date) async throws -> TimerDTO
    func adjustTimerStart(id: UUID, startedAt: Date, at: Date) async throws -> TimerDTO
    func listTimers(childId: UUID?) async throws -> [TimerDTO]

    func exportBundle() async throws -> ExportBundleDTO
    func exportCSV() async throws -> Data
    func dailySummary(childId: UUID, day: String?, from: Date?, to: Date?) async throws -> DailySummaryDTO
}

public extension BenitoService {
    func startTimer(childId: UUID, kind: String, side: String? = nil) async throws -> TimerDTO {
        try await startTimer(childId: childId, kind: kind, side: side, at: Date.now)
    }

    func stopTimer(id: UUID) async throws -> TimerDTO {
        try await stopTimer(id: id, at: Date.now)
    }

    func pauseTimer(id: UUID) async throws -> TimerDTO {
        try await pauseTimer(id: id, at: Date.now)
    }

    func resumeTimer(id: UUID) async throws -> TimerDTO {
        try await resumeTimer(id: id, at: Date.now)
    }

    func adjustTimerStart(id: UUID, startedAt: Date) async throws -> TimerDTO {
        try await adjustTimerStart(id: id, startedAt: startedAt, at: Date.now)
    }

    func dailySummary(childId: UUID, from: Date, to: Date) async throws -> DailySummaryDTO {
        try await dailySummary(childId: childId, day: nil, from: from, to: to)
    }
}

extension APIClient: BenitoService {}
