import CoreLocation
import Foundation
@preconcurrency import MapKit

struct SensorOutboxState: Codable, Hashable, Sendable {
    struct PendingLocation: Codable, Hashable, Sendable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let accuracy: Double
        let recordedAt: Date
    }

    struct PendingHealthSample: Codable, Hashable, Sendable {
        let metric: String
        let value: Double
        let unit: String
        let startAt: Date
        let endAt: Date?

        private static let windowedMetrics: Set<String> = [
            "steps",
            "active_calories",
            "distance_walking",
            "workout_minutes",
            "stand_hours",
            "sleep_duration",
        ]

        var dedupeKey: String {
            if Self.windowedMetrics.contains(metric) {
                return "\(metric)|\(unit)|\(startAt.timeIntervalSince1970)"
            }

            return [
                metric,
                unit,
                String(startAt.timeIntervalSince1970),
                String(endAt?.timeIntervalSince1970 ?? 0)
            ].joined(separator: "|")
        }
    }

    var pendingLocation: PendingLocation?
    var pendingHealthSamples: [PendingHealthSample] = []

    var isEmpty: Bool {
        pendingLocation == nil && pendingHealthSamples.isEmpty
    }

    mutating func enqueue(location update: LocationUpdate) {
        pendingLocation = PendingLocation(
            latitude: update.latitude,
            longitude: update.longitude,
            altitude: update.altitude,
            accuracy: update.accuracy,
            recordedAt: update.timestamp
        )
    }

    mutating func enqueue(healthSamples: [HealthSnapshot.Sample]) {
        for sample in healthSamples {
            let pending = PendingHealthSample(
                metric: sample.metric,
                value: sample.value,
                unit: sample.unit,
                startAt: sample.startAt,
                endAt: sample.endAt
            )
            if let index = pendingHealthSamples.firstIndex(where: { $0.dedupeKey == pending.dedupeKey }) {
                pendingHealthSamples[index] = pending
            } else {
                pendingHealthSamples.append(pending)
            }
        }
    }
}

/// Coordinates durable sensor uploads from the phone to the relay.
///
/// The relay only ACKs a sample once the connector has received and stored it,
/// so sensor state is persisted locally until a real delivery succeeds.
@MainActor
@Observable
final class SensorUploadService {
    private struct SensorLocationBody: Encodable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let accuracy: Double
        let address: String?
        let recordedAt: String
    }

    private struct SensorHealthBody: Encodable {
        struct Sample: Encodable {
            let metric: String
            let value: Double
            let unit: String
            let startAt: String
            let endAt: String?
        }

        let samples: [Sample]
    }

    private struct DeliveryResult: Decodable {
        let deliveryState: String

        var wasDelivered: Bool {
            deliveryState == "delivered"
        }
    }

    private let apiClient: RelayAPIClient
    private let accessTokenProvider: @MainActor () async -> String?
    private let accessTokenRefresher: @MainActor () async -> String?
    private let persistence: AppPersistenceStoreProtocol
    private let isPairedProvider: @MainActor () -> Bool
    private let locationService: LiveLocationService
    private let healthService: LiveHealthService
    private let motionService: LiveMotionService?

    private var isActive = false
    private var isDraining = false
    private var drainGeneration: UInt64 = 0
    private var currentUploadTask: Task<Bool, Never>?
    private var outboxState: SensorOutboxState

    private let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(
        apiClient: RelayAPIClient,
        accessTokenProvider: @escaping @MainActor () async -> String?,
        accessTokenRefresher: @escaping @MainActor () async -> String? = { nil },
        persistence: AppPersistenceStoreProtocol,
        isPairedProvider: @escaping @MainActor () -> Bool,
        locationService: LiveLocationService,
        healthService: LiveHealthService,
        motionService: LiveMotionService? = nil
    ) {
        self.apiClient = apiClient
        self.accessTokenProvider = accessTokenProvider
        self.accessTokenRefresher = accessTokenRefresher
        self.persistence = persistence
        self.isPairedProvider = isPairedProvider
        self.locationService = locationService
        self.healthService = healthService
        self.motionService = motionService
        self.outboxState = persistence.loadSensorOutboxState()
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        outboxState = persistence.loadSensorOutboxState()

        locationService.onLocationUpdate = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive else { return }
                let generation = self.drainGeneration
                self.outboxState.enqueue(location: update)
                self.persistOutboxState()
                await self.drainOutboxIfPossible(generation: generation)
            }
        }

        healthService.onHealthUpdate = { [weak self] changedIdentifiers in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive else { return }
                let generation = self.drainGeneration
                await self.captureHealthSnapshot(
                    generation: generation,
                    changedIdentifiers: changedIdentifiers
                )
            }
        }

        motionService?.onActivityUpdate = { [weak self] activityCode in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive else { return }
                let generation = self.drainGeneration
                let now = Date()
                let sample = HealthSnapshot.Sample(
                    metric: "user_activity",
                    value: Double(activityCode.rawValue),
                    unit: "activity_code",
                    startAt: now,
                    endAt: nil
                )
                self.outboxState.enqueue(healthSamples: [sample])
                self.persistOutboxState()
                await self.drainOutboxIfPossible(generation: generation)
            }
        }

        locationService.startMonitoring()
        healthService.startMonitoring()
        motionService?.startMonitoring()
    }

    func stop() {
        isActive = false
        invalidateDrain()
        currentUploadTask?.cancel()
        currentUploadTask = nil
        locationService.onLocationUpdate = nil
        healthService.onHealthUpdate = nil
        motionService?.onActivityUpdate = nil
        locationService.stopMonitoring()
        healthService.stopMonitoring()
        motionService?.stopMonitoring()
    }

    func resetOutbox() {
        invalidateDrain()
        currentUploadTask?.cancel()
        currentUploadTask = nil
        outboxState = SensorOutboxState()
        persistence.clearSensorOutboxState()
    }

    func handleAppDidBecomeActive() async {
        guard isActive else { return }
        let generation = drainGeneration

        locationService.requestSingleLocation()
        await captureHealthSnapshot(generation: generation, forceFullRefresh: true)
        await drainOutboxIfPossible(generation: generation)
    }

    func handleSystemLaunch() async {
        guard isActive else { return }
        let generation = drainGeneration

        await captureHealthSnapshot(generation: generation)
        await drainOutboxIfPossible(generation: generation)
    }

    private func captureHealthSnapshot(
        generation: UInt64,
        forceFullRefresh: Bool = false,
        changedIdentifiers: Set<String>? = nil
    ) async {
        guard
            let snapshot = await healthService.collectSnapshot(
                forceFullRefresh: forceFullRefresh,
                changedIdentifiers: changedIdentifiers
            )
        else {
            return
        }
        guard isActive, generation == drainGeneration, !Task.isCancelled else { return }
        guard !snapshot.samples.isEmpty else { return }
        outboxState.enqueue(healthSamples: snapshot.samples)
        SharedWidgetDataStore.updateHealthMetrics(from: snapshot.samples)
        persistOutboxState()
        await drainOutboxIfPossible(generation: generation)
    }

    private func drainOutboxIfPossible(generation: UInt64) async {
        guard !isDraining else { return }
        guard isActive else { return }
        guard isPairedProvider() else { return }
        guard generation == drainGeneration, !Task.isCancelled else { return }
        isDraining = true
        defer {
            isDraining = false
            if isActive, generation != drainGeneration {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.drainOutboxIfPossible(generation: self.drainGeneration)
                }
            }
        }

        guard let accessToken = await accessTokenProvider(), !accessToken.isEmpty else {
            return
        }
        _ = accessToken
        guard generation == drainGeneration, isActive else { return }

        while generation == drainGeneration && isActive && isPairedProvider() {
            if let pendingLocation = outboxState.pendingLocation {
                let uploadTask = Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return false }
                    return await self.uploadLocation(pendingLocation)
                }
                currentUploadTask = uploadTask
                let delivered = await uploadTask.value
                currentUploadTask = nil
                guard generation == drainGeneration, isActive else { return }
                guard delivered else { break }
                guard outboxState.pendingLocation == pendingLocation else { continue }
                outboxState.pendingLocation = nil
                persistOutboxState()
                continue
            }

            if !outboxState.pendingHealthSamples.isEmpty {
                let pendingHealthSamples = outboxState.pendingHealthSamples
                let uploadTask = Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return false }
                    return await self.uploadHealth(pendingHealthSamples)
                }
                currentUploadTask = uploadTask
                let delivered = await uploadTask.value
                currentUploadTask = nil
                guard generation == drainGeneration, isActive else { return }
                guard delivered else { break }
                guard outboxState.pendingHealthSamples == pendingHealthSamples else { continue }
                outboxState.pendingHealthSamples.removeAll()
                persistOutboxState()
                continue
            }

            break
        }
    }

    private func invalidateDrain() {
        drainGeneration &+= 1
    }

    private func persistOutboxState() {
        if outboxState.isEmpty {
            persistence.clearSensorOutboxState()
        } else {
            persistence.saveSensorOutboxState(outboxState)
        }
    }

    private func uploadLocation(_ pending: SensorOutboxState.PendingLocation) async -> Bool {
        // Reverse geocode to get a human-readable address
        let address = await reverseGeocode(latitude: pending.latitude, longitude: pending.longitude)
        guard !Task.isCancelled else { return false }

        let body = SensorLocationBody(
            latitude: pending.latitude,
            longitude: pending.longitude,
            altitude: pending.altitude,
            accuracy: pending.accuracy,
            address: address,
            recordedAt: iso8601Formatter.string(from: pending.recordedAt)
        )

        return await performAuthorizedUpload(path: "device/sensor/location", body: body)
    }

    private func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            if #available(iOS 26.0, *) {
                guard let request = MKReverseGeocodingRequest(location: location) else {
                    return nil
                }
                let mapItems = try await request.mapItems
                guard let item = mapItems.first else { return nil }
                if let shortAddress = item.address?.shortAddress, !shortAddress.isEmpty {
                    return shortAddress
                }
                if let fullAddress = item.address?.fullAddress, !fullAddress.isEmpty {
                    return fullAddress
                }
                if let singleLine = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true),
                   !singleLine.isEmpty {
                    return singleLine
                }
                return item.name
            } else {
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
                guard let place = placemarks.first else { return nil }
                let parts = [place.name, place.thoroughfare, place.locality, place.administrativeArea]
                    .compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
        } catch {
            return nil
        }
    }

    private func uploadHealth(_ samples: [SensorOutboxState.PendingHealthSample]) async -> Bool {
        let body = SensorHealthBody(
            samples: samples.map { sample in
                SensorHealthBody.Sample(
                    metric: sample.metric,
                    value: sample.value,
                    unit: sample.unit,
                    startAt: iso8601Formatter.string(from: sample.startAt),
                    endAt: sample.endAt.map { iso8601Formatter.string(from: $0) }
                )
            }
        )

        return await performAuthorizedUpload(path: "device/sensor/health", body: body)
    }

    private func performAuthorizedUpload<Body: Encodable>(path: String, body: Body) async -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            return try await executeUpload(path: path, body: body, accessToken: await accessTokenProvider())
        } catch RelayAPIClient.ClientError.unauthorized {
            guard !Task.isCancelled else { return false }
            guard let refreshedToken = await accessTokenRefresher(), !refreshedToken.isEmpty else {
                return false
            }
            guard !Task.isCancelled else { return false }
            return (try? await executeUpload(path: path, body: body, accessToken: refreshedToken)) ?? false
        } catch {
            return false
        }
    }

    private func executeUpload<Body: Encodable>(path: String, body: Body, accessToken: String?) async throws -> Bool {
        guard !Task.isCancelled else { return false }
        guard let accessToken, !accessToken.isEmpty else {
            return false
        }
        let result: DeliveryResult = try await apiClient.post(
            path: path,
            body: body,
            accessToken: accessToken
        )
        return result.wasDelivered
    }
}
