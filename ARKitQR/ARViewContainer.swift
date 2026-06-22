import SwiftUI
import ARKit
import SceneKit
import Foundation
import CoreMotion
import Kronos
import UIKit

extension Notification.Name {
    static let arInitializationDidComplete = Notification.Name("arInitializationDidComplete")
    static let arStartRequested = Notification.Name("arStartRequested")
}

struct ARKitARViewContainer: UIViewRepresentable {
    @Binding var distance: String
    @Binding var direction: String
    @Binding var anchorPoint: SCNVector3?
    @Binding var resetQRFlag: Bool
    @Binding var shouldResetCSV: Bool
    @Binding var showFeaturePoints: Bool
    @Binding var featureCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let containerView = UIView(frame: .zero)

        let arView = ARSCNView(frame: .zero)
        arView.translatesAutoresizingMaskIntoConstraints = false
        arView.delegate = context.coordinator
        arView.session.delegate = context.coordinator
        arView.contentMode = .scaleAspectFill
        arView.backgroundColor = .black
        arView.debugOptions = []
        arView.scene = SCNScene()

        let featureOverlayView = UIView(frame: .zero)
        featureOverlayView.translatesAutoresizingMaskIntoConstraints = false
        featureOverlayView.backgroundColor = .clear
        featureOverlayView.isUserInteractionEnabled = false
        featureOverlayView.isHidden = !showFeaturePoints

        let featureLayer = CAShapeLayer()
        featureLayer.fillColor = UIColor.systemGreen.cgColor
        featureOverlayView.layer.addSublayer(featureLayer)

        containerView.addSubview(arView)
        containerView.addSubview(featureOverlayView)

        NSLayoutConstraint.activate([
            arView.topAnchor.constraint(equalTo: containerView.topAnchor),
            arView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            arView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            featureOverlayView.topAnchor.constraint(equalTo: containerView.topAnchor),
            featureOverlayView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            featureOverlayView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            featureOverlayView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        context.coordinator.sceneView = arView
        context.coordinator.featureOverlayView = featureOverlayView
        context.coordinator.featureLayer = featureLayer

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = []

        arView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )

        context.coordinator.resetCSVData()
        context.coordinator.initializeTimeSync()

        DispatchQueue.main.async {
            self.distance = "Initializing AR"
            self.direction = "tracking:false map:false features:0/50"
            self.featureCount = 0
        }

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.featureOverlayView?.isHidden = !showFeaturePoints

        if shouldResetCSV {
            context.coordinator.resetAllState()

            DispatchQueue.main.async {
                self.anchorPoint = nil
                self.distance = "Initializing AR"
                self.direction = "tracking:false map:false features:0/50"
                self.featureCount = 0
                self.shouldResetCSV = false
            }
        }
    }

    final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        var parent: ARKitARViewContainer

        weak var sceneView: ARSCNView?
        weak var featureOverlayView: UIView?
        weak var featureLayer: CAShapeLayer?

        var latestFrame: ARFrame?
        var timeOffset: Double = 0.0

        var initializationStartTime: TimeInterval?
        var hasCompletedInitialization = false
        var hasPostedInitializationNotification = false
        var hasStartBeenRequested = false

        var isMeasuring = false
        var measurementAnchor: SCNVector3?

        let initializationRequiredDuration: TimeInterval = 2.0
        let minimumFeatureCount: Int = 50

        let motionManager = CMMotionManager()
        var latestAcceleration = CMAcceleration(x: 0, y: 0, z: 0)

        private var frameIndex: Int = 0

        // 画面に表示する特徴点の大きさを距離に応じて変えるための設定です。
        // 近い特徴点ほど大きく，遠い特徴点ほど小さく表示します。
        private let minFeaturePointRadius: CGFloat = 3.0
        private let maxFeaturePointRadius: CGFloat = 12.0
        private let nearFeatureDistance: Float = 0.2
        private let farFeatureDistance: Float = 3.0

        init(_ parent: ARKitARViewContainer) {
            self.parent = parent
            super.init()

            startAccelerometer()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleStartRequestedNotification),
                name: .arStartRequested,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            motionManager.stopDeviceMotionUpdates()
        }

        func startAccelerometer() {
            guard motionManager.isDeviceMotionAvailable else {
                print("DeviceMotion is not available")
                return
            }

            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0

            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                guard let self = self else { return }

                if let error = error {
                    print("DeviceMotion error: \(error)")
                    return
                }

                guard let motion = motion else { return }

                self.latestAcceleration = motion.userAcceleration
            }
        }

        @objc func handleStartRequestedNotification() {
            guard !isMeasuring else { return }

            guard let currentFrame = sceneView?.session.currentFrame ?? latestFrame else {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.distance = "Start failed"
                    self?.parent.direction = "AR frame not ready"
                }
                return
            }

            let cameraTransform = currentFrame.camera.transform

            let startPosition = SCNVector3(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )

            frameIndex = 0
            measurementAnchor = startPosition
            hasStartBeenRequested = true
            hasCompletedInitialization = true
            isMeasuring = true

            saveCurrentFrameToCSV(frame: currentFrame)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                self.parent.anchorPoint = startPosition
                self.parent.distance = "Measurement started"
                self.parent.direction = "Under tracking!!"
            }
        }

        func initializeTimeSync() {
            Clock.sync { [weak self] date, _ in
                guard let self = self else { return }

                let uptime = ProcessInfo.processInfo.systemUptime

                if let date = date {
                    let kronosTime = date.timeIntervalSince1970
                    self.timeOffset = kronosTime - uptime
                    print("Time source: Kronos")
                    print("Kronos UNIXTIME: \(kronosTime)")
                } else {
                    let fallbackTimestamp = Date().timeIntervalSince1970
                    self.timeOffset = fallbackTimestamp - uptime
                    print("Time source: Local")
                    print("Local UNIXTIME: \(fallbackTimestamp)")
                }

                print("Device Uptime: \(uptime)")
                print("Calculated Offset: \(self.timeOffset)")
            }
        }

        func getCurrentTimestamp(from frame: ARFrame) -> Double {
            let frameTimestamp = frame.timestamp
            let unixTimestamp = frameTimestamp + timeOffset
            return unixTimestamp
        }

        func isTrackingStable(_ frame: ARFrame) -> Bool {
            if case .normal = frame.camera.trackingState {
                return true
            }
            return false
        }

        func isWorldMappingReady(_ frame: ARFrame) -> Bool {
            frame.worldMappingStatus == .extending || frame.worldMappingStatus == .mapped
        }

        func hasEnoughFeaturePoints(_ frame: ARFrame) -> Bool {
            let count = frame.rawFeaturePoints?.points.count ?? 0
            return count >= minimumFeatureCount
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            latestFrame = frame

            let currentFeatureCount = frame.rawFeaturePoints?.points.count ?? 0

            DispatchQueue.main.async { [weak self] in
                self?.parent.featureCount = currentFeatureCount
            }

            updateScreenFeaturePoints(from: frame)

            if !hasCompletedInitialization {
                let trackingStable = isTrackingStable(frame)
                let worldMappingReady = isWorldMappingReady(frame)
                let enoughFeaturePoints = hasEnoughFeaturePoints(frame)

                if trackingStable && worldMappingReady && enoughFeaturePoints {
                    if initializationStartTime == nil {
                        initializationStartTime = frame.timestamp
                    }

                    if let startTime = initializationStartTime,
                       frame.timestamp - startTime >= initializationRequiredDuration {
                        hasCompletedInitialization = true

                        if !hasPostedInitializationNotification {
                            hasPostedInitializationNotification = true

                            DispatchQueue.main.async { [weak self] in
                                guard let self = self else { return }

                                self.parent.distance = "Initialization completed"
                                self.parent.direction = "Press Start"

                                NotificationCenter.default.post(
                                    name: .arInitializationDidComplete,
                                    object: nil
                                )
                            }
                        }
                    }
                } else {
                    initializationStartTime = nil

                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }

                        self.parent.distance = "Initializing AR"
                        self.parent.direction = "tracking:\(trackingStable) map:\(worldMappingReady) features:\(currentFeatureCount)/\(self.minimumFeatureCount)"
                    }
                }
            }

            guard isMeasuring else { return }

            saveCurrentFrameToCSV(frame: frame)
        }

        private func updateScreenFeaturePoints(from frame: ARFrame) {
            guard parent.showFeaturePoints else {
                DispatchQueue.main.async { [weak self] in
                    self?.featureLayer?.path = nil
                    self?.featureOverlayView?.isHidden = true
                }
                return
            }

            guard let sceneView = sceneView,
                  let pointCloud = frame.rawFeaturePoints else {
                DispatchQueue.main.async { [weak self] in
                    self?.featureLayer?.path = nil
                }
                return
            }

            let sceneSize = sceneView.bounds.size

            guard sceneSize.width > 0,
                  sceneSize.height > 0 else {
                return
            }

            let path = CGMutablePath()

            for point in pointCloud.points {
                let projectedPoint = frame.camera.projectPoint(
                    point,
                    orientation: .portrait,
                    viewportSize: sceneSize
                )

                guard projectedPoint.x.isFinite,
                      projectedPoint.y.isFinite else {
                    continue
                }

                guard projectedPoint.x >= 0,
                      projectedPoint.x <= sceneSize.width,
                      projectedPoint.y >= 0,
                      projectedPoint.y <= sceneSize.height else {
                    continue
                }

                let radius = featurePointRadius(
                    for: point,
                    cameraTransform: frame.camera.transform
                )

                let rect = CGRect(
                    x: projectedPoint.x - radius,
                    y: projectedPoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                path.addEllipse(in: rect)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let sceneView = self.sceneView else {
                    return
                }

                self.featureOverlayView?.isHidden = false

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.featureLayer?.frame = sceneView.bounds
                self.featureLayer?.path = path
                CATransaction.commit()
            }
        }

        private func featurePointRadius(
            for point: vector_float3,
            cameraTransform: simd_float4x4
        ) -> CGFloat {
            let cameraPosition = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )

            let distance = simd_length(point - cameraPosition)
            let clampedDistance = min(
                max(distance, nearFeatureDistance),
                farFeatureDistance
            )

            let normalized = (clampedDistance - nearFeatureDistance)
                / (farFeatureDistance - nearFeatureDistance)

            let radius = maxFeaturePointRadius
                - CGFloat(normalized) * (maxFeaturePointRadius - minFeaturePointRadius)

            return radius
        }

        func saveCurrentFrameToCSV(frame: ARFrame) {
            guard let anchor = measurementAnchor else { return }

            let cameraTransform = frame.camera.transform

            let currentPosition = SCNVector3(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )

            let dx = currentPosition.x - anchor.x
            let dy = currentPosition.y - anchor.y
            let dz = currentPosition.z - anchor.z

            let distance = sqrt(dx * dx + dy * dy + dz * dz)
            let directionVector = SCNVector3(dx, dy, dz)
            let timestamp = getCurrentTimestamp(from: frame)
            let features = frame.rawFeaturePoints?.points.count ?? 0

            saveToCSV(
                timestamp: timestamp,
                distance: Float(distance),
                direction: directionVector,
                acceleration: latestAcceleration,
                features: features
            )

            saveFeaturePointsToCSV(
                timestamp: timestamp,
                frame: frame,
                frameIndex: frameIndex
            )

            frameIndex += 1
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            // 記録処理は session(_:didUpdate:) で行う
        }

        func saveToCSV(
            timestamp: Double,
            distance: Float,
            direction: SCNVector3,
            acceleration: CMAcceleration,
            features: Int
        ) {
            let fileName = "ARKitData.csv"
            let path = documentsDirectory().appendingPathComponent(fileName)

            var csvText = ""

            if !FileManager.default.fileExists(atPath: path.path) {
                csvText = "Timestamp,Distance,DirectionX,DirectionY,DirectionZ,AccelerationX,AccelerationY,AccelerationZ,Features\n"
            }

            let ax = acceleration.x * 9.80665
            let ay = acceleration.y * 9.80665
            let az = acceleration.z * 9.80665

            let newLine = String(
                format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d\n",
                timestamp,
                Double(distance),
                Double(direction.x),
                Double(direction.y),
                Double(direction.z),
                ax,
                ay,
                az,
                features
            )

            csvText.append(newLine)
            append(csvText, to: path)
        }

        func saveFeaturePointsToCSV(
            timestamp: Double,
            frame: ARFrame,
            frameIndex: Int
        ) {
            let fileName = "ARKitFeaturePoints.csv"
            let path = documentsDirectory().appendingPathComponent(fileName)

            guard let pointCloud = frame.rawFeaturePoints else {
                return
            }

            let points = pointCloud.points
            let identifiers = pointCloud.identifiers
            let featureCount = points.count

            let viewportSize: CGSize

            if let sceneView = sceneView,
               sceneView.bounds.width > 0,
               sceneView.bounds.height > 0 {
                viewportSize = sceneView.bounds.size
            } else {
                viewportSize = CGSize(width: 0, height: 0)
            }

            var csvText = ""

            if !FileManager.default.fileExists(atPath: path.path) {
                csvText = "Timestamp,FrameIndex,FeatureIndex,FeatureID,X,Y,Z,ScreenX,ScreenY,FeatureCount\n"
            }

            csvText.reserveCapacity(max(featureCount, 1) * 120)

            for i in 0..<featureCount {
                let point = points[i]
                let identifier = i < identifiers.count ? identifiers[i] : 0

                let projectedPoint: CGPoint

                if viewportSize.width > 0,
                   viewportSize.height > 0 {
                    projectedPoint = frame.camera.projectPoint(
                        point,
                        orientation: .portrait,
                        viewportSize: viewportSize
                    )
                } else {
                    projectedPoint = CGPoint(
                        x: CGFloat.nan,
                        y: CGFloat.nan
                    )
                }

                let line = String(
                    format: "%.6f,%d,%d,%llu,%.6f,%.6f,%.6f,%.6f,%.6f,%d\n",
                    timestamp,
                    frameIndex,
                    i,
                    identifier,
                    Double(point.x),
                    Double(point.y),
                    Double(point.z),
                    Double(projectedPoint.x),
                    Double(projectedPoint.y),
                    featureCount
                )

                csvText.append(line)
            }

            append(csvText, to: path)
        }

        func resetCSVData() {
            let dataPath = documentsDirectory().appendingPathComponent("ARKitData.csv")
            let featurePath = documentsDirectory().appendingPathComponent("ARKitFeaturePoints.csv")

            let dataHeader = "Timestamp,Distance,DirectionX,DirectionY,DirectionZ,AccelerationX,AccelerationY,AccelerationZ,Features\n"
            let featureHeader = "Timestamp,FrameIndex,FeatureIndex,FeatureID,X,Y,Z,ScreenX,ScreenY,FeatureCount\n"

            measurementAnchor = nil
            isMeasuring = false
            frameIndex = 0

            do {
                try dataHeader.write(
                    to: dataPath,
                    atomically: true,
                    encoding: .utf8
                )

                try featureHeader.write(
                    to: featurePath,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                print("Failed to reset CSV file")
                print("\(error)")
            }
        }

        func resetAllState() {
            resetCSVData()

            isMeasuring = false
            initializationStartTime = nil
            hasCompletedInitialization = false
            hasPostedInitializationNotification = false
            hasStartBeenRequested = false
            measurementAnchor = nil
            latestFrame = nil

            DispatchQueue.main.async { [weak self] in
                self?.featureLayer?.path = nil
            }

            guard let sceneView = sceneView else { return }

            sceneView.scene.rootNode.enumerateChildNodes { node, _ in
                if node.name == "anchorX" {
                    node.removeFromParentNode()
                }
            }

            sceneView.session.pause()

            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = []

            sceneView.session.run(
                configuration,
                options: [.resetTracking, .removeExistingAnchors]
            )
        }

        private func documentsDirectory() -> URL {
            FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
        }

        private func append(_ text: String, to path: URL) {
            do {
                if let fileHandle = FileHandle(forWritingAtPath: path.path) {
                    defer {
                        fileHandle.closeFile()
                    }

                    fileHandle.seekToEndOfFile()

                    if let data = text.data(using: .utf8) {
                        fileHandle.write(data)
                    }
                } else {
                    try text.write(
                        to: path,
                        atomically: true,
                        encoding: .utf8
                    )
                }
            } catch {
                print("Failed to write CSV file")
                print("\(error)")
            }
        }
    }
}
