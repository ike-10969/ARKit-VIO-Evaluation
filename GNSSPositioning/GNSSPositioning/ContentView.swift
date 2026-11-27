import CoreLocation
import SwiftUI

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    positionCard
                    measurementCard
                    recordingCard

                    if let errorMessage = locationManager.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }

                    if let csvErrorMessage = locationManager.csvErrorMessage {
                        Label(csvErrorMessage, systemImage: "doc.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }

                    actionButton
                    shareButton

                    Text("iPhoneのCore Locationは、GNSS・Wi-Fi・基地局・端末センサーを統合して位置を算出します。空が見える屋外では、一般にGNSSの精度が得やすくなります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("GNSS測位")
        }
    }

    private var statusCard: some View {
        InfoCard(title: "測位状態", systemImage: "location.fill") {
            LabeledValue(label: "状態", value: locationManager.isUpdating ? "測位中" : "停止中")
            LabeledValue(label: "記録準備", value: recordingStatusText)
            LabeledValue(label: "位置情報権限", value: authorizationText)
            LabeledValue(label: "精度権限", value: accuracyAuthorizationText)
        }
    }

    private var positionCard: some View {
        InfoCard(title: "現在位置", systemImage: "globe.asia.australia.fill") {
            LabeledValue(
                label: "緯度",
                value: coordinateText(locationManager.location?.coordinate.latitude)
            )
            LabeledValue(
                label: "経度",
                value: coordinateText(locationManager.location?.coordinate.longitude)
            )
            LabeledValue(
                label: "高度",
                value: measurementText(locationManager.location?.altitude, unit: "m")
            )
        }
    }

    private var measurementCard: some View {
        InfoCard(title: "測位データ", systemImage: "scope") {
            LabeledValue(
                label: "水平精度",
                value: accuracyText(locationManager.location?.horizontalAccuracy)
            )
            LabeledValue(
                label: "垂直精度",
                value: accuracyText(locationManager.location?.verticalAccuracy)
            )
            LabeledValue(
                label: "速度",
                value: speedText(locationManager.location?.speed)
            )
            LabeledValue(
                label: "Timestamp",
                value: timestampText(locationManager.location?.timestamp)
            )
            LabeledValue(
                label: "SystemUptime",
                value: uptimeText(locationManager.locationSystemUptime)
            )
        }
    }

    private var recordingCard: some View {
        InfoCard(title: "CSV記録", systemImage: "tablecells") {
            VStack(alignment: .leading, spacing: 8) {
                Text("記録開始の水平精度")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("記録開始の水平精度", selection: $locationManager.requiredHorizontalAccuracy) {
                    Text("5 m").tag(5.0)
                    Text("10 m").tag(10.0)
                    Text("20 m").tag(20.0)
                    Text("50 m").tag(50.0)
                }
                .pickerStyle(.segmented)
                .disabled(locationManager.isUpdating)
            }

            Divider()

            LabeledValue(label: "記録状態", value: recordingStatusText)
            LabeledValue(
                label: "開始条件",
                value: "≤ \(locationManager.requiredHorizontalAccuracy.formatted()) m"
            )
            LabeledValue(label: "GNSS点", value: "\(locationManager.recordedPointCount)")
            LabeledValue(label: "欠測点", value: "\(locationManager.missingPointCount)")
            LabeledValue(
                label: "ファイル",
                value: csvFilenameText
            )

            if locationManager.isWaitingForAccuracy {
                Text("条件を満たす測位点を取得すると、その点をENU座標の原点としてCSV記録を開始します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionButton: some View {
        Button {
            if locationManager.isUpdating {
                locationManager.stopUpdating()
            } else {
                locationManager.requestPermissionOrStart()
            }
        } label: {
            Label(
                locationManager.isUpdating ? "測位・記録を停止" : "測位・記録を開始",
                systemImage: locationManager.isUpdating ? "stop.circle.fill" : "location.circle.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(locationManager.isUpdating ? .red : .blue)
        .controlSize(.large)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let csvFileURL = locationManager.csvFileURL {
            ShareLink(item: csvFileURL) {
                Label("CSVを送信・保存", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(locationManager.isUpdating)

            if locationManager.isUpdating {
                Text("CSVを確定して送信するには、先に測位を停止してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordingStatusText: String {
        if locationManager.isRecording {
            return "記録中"
        }
        if locationManager.isWaitingForAccuracy {
            return "精度待機中"
        }
        return "停止中"
    }

    private var csvFilenameText: String {
        if locationManager.isWaitingForAccuracy {
            return "精度確定後に作成"
        }
        return locationManager.csvFileURL?.lastPathComponent ?? "—"
    }

    private var authorizationText: String {
        switch locationManager.authorizationStatus {
        case .notDetermined: "未選択"
        case .restricted: "制限あり"
        case .denied: "許可なし"
        case .authorizedAlways: "常に許可"
        case .authorizedWhenInUse: "使用中のみ許可"
        @unknown default: "不明"
        }
    }

    private var accuracyAuthorizationText: String {
        switch locationManager.accuracyAuthorization {
        case .fullAccuracy: "正確な位置情報"
        case .reducedAccuracy: "おおよその位置情報"
        @unknown default: "不明"
        }
    }

    private func coordinateText(_ value: CLLocationDegrees?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(7))) + "°"
    }

    private func measurementText(_ value: CLLocationDistance?, unit: String) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + " \(unit)"
    }

    private func accuracyText(_ value: CLLocationAccuracy?) -> String {
        guard let value, value >= 0 else { return "—" }
        return "±" + value.formatted(.number.precision(.fractionLength(1))) + " m"
    }

    private func speedText(_ value: CLLocationSpeed?) -> String {
        guard let value, value >= 0 else { return "—" }
        let kilometersPerHour = value * 3.6
        return kilometersPerHour.formatted(.number.precision(.fractionLength(1))) + " km/h"
    }

    private func timestampText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            date.timeIntervalSince1970
        )
    }

    private func uptimeText(_ uptime: TimeInterval?) -> String {
        guard let uptime else { return "—" }
        return String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            uptime
        )
    }
}

private struct InfoCard<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.tint)

            Divider()
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontDesign(.monospaced)
                .multilineTextAlignment(.trailing)
        }
    }
}
