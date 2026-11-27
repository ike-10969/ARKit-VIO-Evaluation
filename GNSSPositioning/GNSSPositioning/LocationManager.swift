import CoreLocation
import Foundation

@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var locationSystemUptime: TimeInterval?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var isUpdating = false
    @Published private(set) var isWaitingForAccuracy = false
    @Published private(set) var errorMessage: String?

    @Published var requiredHorizontalAccuracy: CLLocationAccuracy = 10
    @Published private(set) var isRecording = false
    @Published private(set) var recordedPointCount = 0
    @Published private(set) var missingPointCount = 0
    @Published private(set) var csvFileURL: URL?
    @Published private(set) var csvErrorMessage: String?

    private let manager = CLLocationManager()
    private var startWhenAuthorized = false
    private var measurementStartedAt: Date?
    private var recordingStartedAt: Date?
    private var sessionAccuracyThreshold: CLLocationAccuracy = 10
    private var lastRecordedTimestamp: Date?
    private var lastRecordedSystemUptime: TimeInterval?
    private var enuOrigin: ENUOrigin?

    private static let expectedLocationInterval: TimeInterval = 1
    private static let maximumGoodSpeedAccuracy: CLLocationSpeedAccuracy = 2
    private static let maximumGoodCourseAccuracy: CLLocationDirectionAccuracy = 20
    private static let csvHeader = [
        "Timestamp",
        "SystemUptime",
        "Latitude",
        "Longitude",
        "Altitude",
        "EllipsoidalAltitude",
        "East",
        "North",
        "Up",
        "OriginLatitude",
        "OriginLongitude",
        "OriginEllipsoidalAltitude",
        "RequiredHorizontalAccuracy",
        "ExpectedInterval",
        "HorizontalAccuracy",
        "VerticalAccuracy",
        "Speed",
        "SpeedAccuracy",
        "Course",
        "CourseAccuracy",
        "QualityFlags"
    ].joined(separator: ",") + "\n"
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    override init() {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false

        restoreLatestCSVFile()
    }

    var canStartUpdating: Bool {
        authorizationStatus == .authorizedWhenInUse ||
            authorizationStatus == .authorizedAlways
    }

    func requestPermissionOrStart() {
        errorMessage = nil
        csvErrorMessage = nil
        startWhenAuthorized = true

        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdating()
        case .denied, .restricted:
            startWhenAuthorized = false
            errorMessage = "位置情報の利用が許可されていません。設定アプリで位置情報を許可してください。"
        @unknown default:
            startWhenAuthorized = false
            errorMessage = "位置情報の権限状態を確認できませんでした。"
        }
    }

    func startUpdating() {
        guard canStartUpdating else {
            requestPermissionOrStart()
            return
        }
        guard isUpdating == false else { return }

        errorMessage = nil
        csvErrorMessage = nil
        startWhenAuthorized = true
        measurementStartedAt = Date()
        recordingStartedAt = nil
        sessionAccuracyThreshold = requiredHorizontalAccuracy
        lastRecordedTimestamp = nil
        lastRecordedSystemUptime = nil
        enuOrigin = nil
        recordedPointCount = 0
        missingPointCount = 0
        isWaitingForAccuracy = true
        isUpdating = true
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        if isRecording {
            appendTrailingMissingRows(until: Date())
        }

        manager.stopUpdatingLocation()
        startWhenAuthorized = false
        measurementStartedAt = nil
        isUpdating = false
        isWaitingForAccuracy = false
        stopCSVRecording()
    }

    private func startCSVRecording(origin location: CLLocation) -> Bool {
        csvErrorMessage = nil

        do {
            let documentsDirectory = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let filename = "GNSS_\(Self.filenameTimestamp(from: location.timestamp)).csv"
            let fileURL = Self.availableFileURL(
                in: documentsDirectory,
                preferredFilename: filename
            )

            try Self.csvHeader.write(to: fileURL, atomically: true, encoding: .utf8)

            csvFileURL = fileURL
            recordingStartedAt = location.timestamp
            sessionAccuracyThreshold = requiredHorizontalAccuracy
            lastRecordedTimestamp = nil
            lastRecordedSystemUptime = nil
            enuOrigin = ENUOrigin(location: location)
            recordedPointCount = 0
            missingPointCount = 0
            isWaitingForAccuracy = false
            isRecording = true
            return true
        } catch {
            csvErrorMessage = "CSVファイルを作成できませんでした: \(error.localizedDescription)"
            isRecording = false
            return false
        }
    }

    private func stopCSVRecording() {
        isRecording = false
        recordingStartedAt = nil
        lastRecordedTimestamp = nil
        lastRecordedSystemUptime = nil
        enuOrigin = nil
    }

    private func record(
        _ location: CLLocation,
        receiptDate: Date,
        receiptSystemUptime: TimeInterval
    ) {
        guard
            isRecording,
            let fileURL = csvFileURL,
            let enuOrigin,
            location.horizontalAccuracy >= 0,
            let recordingStartedAt,
            location.timestamp >= recordingStartedAt,
            lastRecordedTimestamp.map({ location.timestamp > $0 }) ?? true
        else {
            return
        }

        let sampleSystemUptime = Self.systemUptime(
            for: location.timestamp,
            receiptDate: receiptDate,
            receiptSystemUptime: receiptSystemUptime
        )

        do {
            if let previousTimestamp = lastRecordedTimestamp,
               let previousSystemUptime = lastRecordedSystemUptime {
                try appendMissingRows(
                    to: fileURL,
                    after: previousTimestamp,
                    previousSystemUptime: previousSystemUptime,
                    before: location.timestamp,
                    origin: enuOrigin
                )
            }

            let enu = enuOrigin.convert(location: location)
            let fields = [
                Self.decimal(location.timestamp.timeIntervalSince1970, places: 6),
                Self.decimal(sampleSystemUptime, places: 6),
                Self.decimal(location.coordinate.latitude, places: 9),
                Self.decimal(location.coordinate.longitude, places: 9),
                Self.decimal(location.altitude, places: 3),
                Self.decimal(location.ellipsoidalAltitude, places: 3),
                Self.decimal(enu.east, places: 3),
                Self.decimal(enu.north, places: 3),
                Self.decimal(enu.up, places: 3),
                Self.decimal(enuOrigin.latitude, places: 9),
                Self.decimal(enuOrigin.longitude, places: 9),
                Self.decimal(enuOrigin.ellipsoidalAltitude, places: 3),
                Self.decimal(sessionAccuracyThreshold, places: 3),
                Self.decimal(Self.expectedLocationInterval, places: 3),
                Self.decimal(location.horizontalAccuracy, places: 3),
                Self.decimal(location.verticalAccuracy, places: 3),
                Self.decimal(location.speed, places: 3),
                Self.decimal(location.speedAccuracy, places: 3),
                Self.decimal(location.course, places: 3),
                Self.decimal(location.courseAccuracy, places: 3),
                qualityFlags(for: location).joined(separator: ";")
            ]

            try Self.appendCSVLine(fields, to: fileURL)
            lastRecordedTimestamp = location.timestamp
            lastRecordedSystemUptime = sampleSystemUptime
            recordedPointCount += 1
            csvErrorMessage = nil
        } catch {
            failRecording(with: "CSVへの記録に失敗しました: \(error.localizedDescription)")
        }
    }

    private func appendMissingRows(
        to fileURL: URL,
        after previousTimestamp: Date,
        previousSystemUptime: TimeInterval,
        before currentTimestamp: Date,
        origin: ENUOrigin
    ) throws {
        let interval = currentTimestamp.timeIntervalSince(previousTimestamp)
        let estimatedPeriods = max(
            1,
            Int((interval / Self.expectedLocationInterval).rounded())
        )
        let missingCount = estimatedPeriods - 1

        guard missingCount > 0 else { return }

        for offset in 1...missingCount {
            let timeOffset = Double(offset) * Self.expectedLocationInterval
            let missingTimestamp = previousTimestamp.addingTimeInterval(timeOffset)
            guard missingTimestamp < currentTimestamp else { break }

            try appendMissingRow(
                to: fileURL,
                timestamp: missingTimestamp,
                systemUptime: previousSystemUptime + timeOffset,
                origin: origin
            )
        }
    }

    private func appendTrailingMissingRows(until endDate: Date) {
        guard
            isRecording,
            let fileURL = csvFileURL,
            let previousTimestamp = lastRecordedTimestamp,
            let previousSystemUptime = lastRecordedSystemUptime,
            let enuOrigin
        else {
            return
        }

        let elapsed = endDate.timeIntervalSince(previousTimestamp)
        let missingCount = max(
            0,
            Int(floor(elapsed / Self.expectedLocationInterval))
        )
        guard missingCount > 0 else { return }

        do {
            for offset in 1...missingCount {
                let timeOffset = Double(offset) * Self.expectedLocationInterval
                try appendMissingRow(
                    to: fileURL,
                    timestamp: previousTimestamp.addingTimeInterval(timeOffset),
                    systemUptime: previousSystemUptime + timeOffset,
                    origin: enuOrigin
                )
            }
        } catch {
            csvErrorMessage = "欠測行の記録に失敗しました: \(error.localizedDescription)"
        }
    }

    private func appendMissingRow(
        to fileURL: URL,
        timestamp: Date,
        systemUptime: TimeInterval,
        origin: ENUOrigin
    ) throws {
        let fields = [
            Self.decimal(timestamp.timeIntervalSince1970, places: 6),
            Self.decimal(systemUptime, places: 6),
            "", "", "", "", "", "", "",
            Self.decimal(origin.latitude, places: 9),
            Self.decimal(origin.longitude, places: 9),
            Self.decimal(origin.ellipsoidalAltitude, places: 3),
            Self.decimal(sessionAccuracyThreshold, places: 3),
            Self.decimal(Self.expectedLocationInterval, places: 3),
            "", "", "", "", "", "",
            "MISSING_LOCATION"
        ]

        try Self.appendCSVLine(fields, to: fileURL)
        missingPointCount += 1
    }

    private func qualityFlags(for location: CLLocation) -> [String] {
        var flags: [String] = []

        if location.horizontalAccuracy > sessionAccuracyThreshold {
            flags.append("LOW_HORIZONTAL_ACCURACY")
        }

        if location.verticalAccuracy < 0 {
            flags.append("MISSING_VERTICAL_ACCURACY")
        } else if location.verticalAccuracy > max(10, sessionAccuracyThreshold * 2) {
            flags.append("LOW_VERTICAL_ACCURACY")
        }

        if location.speed < 0 {
            flags.append("MISSING_SPEED")
        }
        if location.speedAccuracy < 0 {
            flags.append("MISSING_SPEED_ACCURACY")
        } else if location.speedAccuracy > Self.maximumGoodSpeedAccuracy {
            flags.append("LOW_SPEED_ACCURACY")
        }

        if location.course < 0 {
            flags.append("MISSING_COURSE")
        }
        if location.courseAccuracy < 0 {
            flags.append("MISSING_COURSE_ACCURACY")
        } else if location.courseAccuracy > Self.maximumGoodCourseAccuracy {
            flags.append("LOW_COURSE_ACCURACY")
        }

        return flags.isEmpty ? ["OK"] : flags
    }

    private func failRecording(with message: String) {
        csvErrorMessage = message
        manager.stopUpdatingLocation()
        startWhenAuthorized = false
        measurementStartedAt = nil
        isUpdating = false
        isWaitingForAccuracy = false
        stopCSVRecording()
    }

    private func restoreLatestCSVFile() {
        guard
            let documentsDirectory = try? FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ),
            let files = try? FileManager.default.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return
        }

        csvFileURL = files
            .filter { $0.pathExtension.lowercased() == "csv" && $0.lastPathComponent.hasPrefix("GNSS_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    private static func appendCSVLine(_ fields: [String], to fileURL: URL) throws {
        let line = fields.joined(separator: ",") + "\n"
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        defer { try? fileHandle.close() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data(line.utf8))
    }

    private static func systemUptime(
        for timestamp: Date,
        receiptDate: Date,
        receiptSystemUptime: TimeInterval
    ) -> TimeInterval {
        receiptSystemUptime + timestamp.timeIntervalSince(receiptDate)
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(
            format: "%.*f",
            locale: posixLocale,
            places,
            value
        )
    }

    private static func filenameTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter.string(from: date)
    }

    private static func availableFileURL(
        in directory: URL,
        preferredFilename: String
    ) -> URL {
        let preferredURL = directory.appendingPathComponent(preferredFilename)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        for suffix in 2...999 {
            let candidate = directory.appendingPathComponent("\(baseName)_\(suffix).csv")
            if FileManager.default.fileExists(atPath: candidate.path) == false {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(baseName)_\(UUID().uuidString).csv")
    }
}

extension LocationManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if startWhenAuthorized, isUpdating == false {
                startUpdating()
            }
        case .denied, .restricted:
            stopUpdating()
            errorMessage = "位置情報の利用が許可されていません。設定アプリで位置情報を許可してください。"
        case .notDetermined:
            break
        @unknown default:
            stopUpdating()
            errorMessage = "位置情報の権限状態を確認できませんでした。"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let receiptDate = Date()
        let receiptSystemUptime = ProcessInfo.processInfo.systemUptime

        if let newestLocation = locations.last(where: { $0.horizontalAccuracy >= 0 }) {
            location = newestLocation
            locationSystemUptime = Self.systemUptime(
                for: newestLocation.timestamp,
                receiptDate: receiptDate,
                receiptSystemUptime: receiptSystemUptime
            )
            accuracyAuthorization = manager.accuracyAuthorization
            errorMessage = nil
        }

        let orderedLocations = locations.sorted { $0.timestamp < $1.timestamp }
        for sample in orderedLocations {
            guard
                sample.horizontalAccuracy >= 0,
                let measurementStartedAt,
                sample.timestamp >= measurementStartedAt.addingTimeInterval(-1)
            else {
                continue
            }

            if isWaitingForAccuracy,
               sample.horizontalAccuracy <= requiredHorizontalAccuracy {
                guard startCSVRecording(origin: sample) else {
                    failRecording(with: csvErrorMessage ?? "CSV記録を開始できませんでした。")
                    return
                }
            }

            record(
                sample,
                receiptDate: receiptDate,
                receiptSystemUptime: receiptSystemUptime
            )
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let locationError = error as? CLError

        if locationError?.code == .locationUnknown {
            errorMessage = "位置を特定中です。空が見える場所でしばらくお待ちください。"
            return
        }

        errorMessage = "位置情報を取得できませんでした: \(error.localizedDescription)"
        stopUpdating()
    }
}

private struct ENUOrigin {
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
    let ellipsoidalAltitude: CLLocationDistance

    private let latitudeRadians: Double
    private let longitudeRadians: Double
    private let ecefX: Double
    private let ecefY: Double
    private let ecefZ: Double

    init(location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        ellipsoidalAltitude = location.ellipsoidalAltitude
        latitudeRadians = location.coordinate.latitude * .pi / 180
        longitudeRadians = location.coordinate.longitude * .pi / 180

        let ecef = Self.ecef(
            latitudeRadians: latitudeRadians,
            longitudeRadians: longitudeRadians,
            ellipsoidalAltitude: ellipsoidalAltitude
        )
        ecefX = ecef.x
        ecefY = ecef.y
        ecefZ = ecef.z
    }

    func convert(location: CLLocation) -> (east: Double, north: Double, up: Double) {
        let targetLatitude = location.coordinate.latitude * .pi / 180
        let targetLongitude = location.coordinate.longitude * .pi / 180
        let target = Self.ecef(
            latitudeRadians: targetLatitude,
            longitudeRadians: targetLongitude,
            ellipsoidalAltitude: location.ellipsoidalAltitude
        )

        let deltaX = target.x - ecefX
        let deltaY = target.y - ecefY
        let deltaZ = target.z - ecefZ

        let sinLatitude = sin(latitudeRadians)
        let cosLatitude = cos(latitudeRadians)
        let sinLongitude = sin(longitudeRadians)
        let cosLongitude = cos(longitudeRadians)

        let east = -sinLongitude * deltaX + cosLongitude * deltaY
        let north = -sinLatitude * cosLongitude * deltaX
            - sinLatitude * sinLongitude * deltaY
            + cosLatitude * deltaZ
        let up = cosLatitude * cosLongitude * deltaX
            + cosLatitude * sinLongitude * deltaY
            + sinLatitude * deltaZ

        return (east, north, up)
    }

    private static func ecef(
        latitudeRadians: Double,
        longitudeRadians: Double,
        ellipsoidalAltitude: Double
    ) -> (x: Double, y: Double, z: Double) {
        let semiMajorAxis = 6_378_137.0
        let flattening = 1.0 / 298.257_223_563
        let eccentricitySquared = flattening * (2 - flattening)
        let sinLatitude = sin(latitudeRadians)
        let cosLatitude = cos(latitudeRadians)
        let sinLongitude = sin(longitudeRadians)
        let cosLongitude = cos(longitudeRadians)
        let primeVerticalRadius = semiMajorAxis
            / sqrt(1 - eccentricitySquared * sinLatitude * sinLatitude)

        let x = (primeVerticalRadius + ellipsoidalAltitude)
            * cosLatitude * cosLongitude
        let y = (primeVerticalRadius + ellipsoidalAltitude)
            * cosLatitude * sinLongitude
        let z = (primeVerticalRadius * (1 - eccentricitySquared) + ellipsoidalAltitude)
            * sinLatitude

        return (x, y, z)
    }
}
