import SwiftUI
import MessageUI
import SceneKit

struct ContentView: View {
    @State private var isShowingMailView = false
    @State private var mailResult: Result<MFMailComposeResult, Error>? = nil
    @State private var distance: String = "Initializing AR"
    @State private var direction: String = "tracking:false map:false features:0/50"
    @State private var anchorPoint: SCNVector3?
    @State private var resetQRFlag = false
    @State private var shouldResetCSV = false
    @State private var showMail = false
    @State private var mailTimer: Timer? = nil
    @State private var isStartEnabled = false
    @State private var showFeaturePoints = false
    @State private var featureCount = 0
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ARKitARViewContainer(
                distance: $distance,
                direction: $direction,
                anchorPoint: $anchorPoint,
                resetQRFlag: $resetQRFlag,
                shouldResetCSV: $shouldResetCSV,
                showFeaturePoints: $showFeaturePoints,
                featureCount: $featureCount
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                HStack {
                    Toggle("Points", isOn: $showFeaturePoints)
                        .labelsHidden()

                    Text("Features: \(featureCount)")
                        .font(.caption)
                        .monospacedDigit()

                    Spacer()

                    Button("Start") {
                        NotificationCenter.default.post(name: .arStartRequested, object: nil)
                        mailTimer?.invalidate()
                        mailTimer = Timer.scheduledTimer(withTimeInterval: 210, repeats: false) { _ in
                            showMail = true
                        }
                        isStartEnabled = false
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isStartEnabled ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .disabled(!isStartEnabled)
                }

                HStack(spacing: 8) {
                    Text(distance)
                        .lineLimit(1)
                    Text(direction)
                        .lineLimit(1)
                }
                .font(.caption2)

                HStack {
                    Button("Reset") {
                        anchorPoint = nil
                        distance = "Initializing AR"
                        direction = "tracking:false map:false features:0/50"
                        isStartEnabled = false
                        shouldResetCSV = true
                    }
                    .font(.caption)

                    Spacer()

                    Button("Send Email") {
                        self.isShowingMailView.toggle()
                    }
                    .font(.caption)
                    .disabled(!MFMailComposeViewController.canSendMail())
                }
            }
            .padding(10)
            .background(.ultraThinMaterial)
            .cornerRadius(14)
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $isShowingMailView) {
            MailView(isShowing: self.$isShowingMailView, result: self.$mailResult)
        }
        .sheet(isPresented: $showMail) {
            MailView(isShowing: $showMail, result: $mailResult)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arInitializationDidComplete)) { _ in
            isStartEnabled = true
        }
        .onDisappear {
            mailTimer?.invalidate()
            mailTimer = nil
        }
    }
}
