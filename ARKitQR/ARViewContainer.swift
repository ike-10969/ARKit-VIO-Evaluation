import SwiftUI
import ARKit
import SceneKit
import Foundation
import CoreMotion
import UIKit

// Implementation policy:
// Do not use GPS, CoreLocation, location permissions, or geographic coordinates.
// Track movement only in ARKit's local coordinate system relative to the start point.

extension Notification.Name {
    static let arInitializationDidComplete = Notification.Name("arInitializationDidComplete")
    static let arStartRequested = Notification.Name("arStartRequested")
    static let arDataExportRequested = Notification.Name("arDataExportRequested")
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
        private let motionQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "ARKitQR.IMU.CallbackQueue"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private let imuWriteQueue = DispatchQueue(label: "ARKitQR.IMU.WriteQueue")

        var latestAcceleration = CMAcceleration(x: 0, y: 0, z: 0)

        private var isIMURecording = false
        private var rawAccelerometerFileHandle: FileHandle?
        private var rawGyroscopeFileHandle: FileHandle?
        private var deviceMotionFileHandle: FileHandle?

        private let standardGravity = 9.80665

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

            startMotionUpdates()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleStartRequestedNotification),
                name: .arStartRequested,
                object: nil
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDataExportRequestedNotification),
                name: .arDataExportRequested,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            stopMotionUpdates()

            imuWriteQueue.sync {
                isIMURecording = false
                closeIMUFiles()
            }
        }

        func startMotionUpdates() {
            let updateInterval = 1.0 / 100.0

            motionManager.accelerometerUpdateInterval = updateInterval
            motionManager.gyroUpdateInterval = updateInterval
            motionManager.deviceMotionUpdateInterval = updateInterval

            if motionManager.isAccelerometerAvailable {
                motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
                    guard let self = self else { return }

                    if let error = error {
                        print("Raw accelerometer error: \(error)")
                        return
                    }

                    guard let data = data else { return }

                    let acceleration = data.acceleration
                    let unixTimestamp = data.timestamp + self.timeOffset
                    let line = String(
                        format: "%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f\n",
                        data.timestamp,
                        unixTimestamp,
                        acceleration.x,
                        acceleration.y,
                        acceleration.z,
                        acceleration.x * self.standardGravity,
                        acceleration.y * self.standardGravity,
                        acceleration.z * self.standardGravity
                    )

                    self.imuWriteQueue.async { [weak self] in
                        guard let self = self, self.isIMURecording else { return }
                        self.appendIMULine(line, to: self.rawAccelerometerFileHandle)
                    }
                }
            } else {
                print("Raw accelerometer is not available")
            }

            if motionManager.isGyroAvailable {
                motionManager.startGyroUpdates(to: motionQueue) { [weak self] data, error in
                    guard let self = self else { return }

                    if let error = error {
                        print("Raw gyroscope error: \(error)")
                        return
                    }

                    guard let data = data else { return }

                    let rotationRate = data.rotationRate
                    let unixTimestamp = data.timestamp + self.timeOffset
                    let line = String(
                        format: "%.9f,%.9f,%.9f,%.9f,%.9f\n",
                        data.timestamp,
                        unixTimestamp,
                        rotationRate.x,
                        rotationRate.y,
                        rotationRate.z
                    )

                    self.imuWriteQueue.async { [weak self] in
                        guard let self = self, self.isIMURecording else { return }
                        self.appendIMULine(line, to: self.rawGyroscopeFileHandle)
                    }
                }
            } else {
                print("Raw gyroscope is not available")
            }

            guard motionManager.isDeviceMotionAvailable else {
                print("DeviceMotion is not available")
                return
            }

            motionManager.startDeviceMotionUpdates(
                using: .xArbitraryZVertical,
                to: motionQueue
            ) { [weak self] motion, error in
                guard let self = self else { return }

                if let error = error {
                    print("DeviceMotion error: \(error)")
                    return
                }

                guard let motion = motion else { return }

                let gravity = motion.gravity
                let userAcceleration = motion.userAcceleration
                let rotationRate = motion.rotationRate
                let quaternion = motion.attitude.quaternion
                let unixTimestamp = motion.timestamp + self.timeOffset

                let line = String(
                    format: "%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,xArbitraryZVertical\n",
                    motion.timestamp,
                    unixTimestamp,
                    gravity.x,
                    gravity.y,
                    gravity.z,
                    userAcceleration.x,
                    userAcceleration.y,
                    userAcceleration.z,
                    userAcceleration.x * self.standardGravity,
                    userAcceleration.y * self.standardGravity,
                    userAcceleration.z * self.standardGravity,
                    rotationRate.x,
                    rotationRate.y,
                    rotationRate.z,
                    quaternion.x,
                    quaternion.y,
                    quaternion.z,
                    quaternion.w,
                    motion.attitude.roll,
                    motion.attitude.pitch,
                    motion.attitude.yaw
                )

                DispatchQueue.main.async { [weak self] in
                    self?.latestAcceleration = userAcceleration
                }

                self.imuWriteQueue.async { [weak self] in
                    guard let self = self, self.isIMURecording else { return }
                    self.appendIMULine(line, to: self.deviceMotionFileHandle)
                }
            }
        }

        func stopMotionUpdates() {
            motionManager.stopAccelerometerUpdates()
            motionManager.stopGyroUpdates()
            motionManager.stopDeviceMotionUpdates()
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

            beginIMURecording()

            saveCurrentFrameToCSV(frame: currentFrame)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                self.parent.anchorPoint = startPosition
                self.parent.distance = "Measurement started"
                self.parent.direction = "Under tracking!!"
            }
        }

        @objc func handleDataExportRequestedNotification() {
            imuWriteQueue.sync {
                synchronizeIMUFiles()
            }
        }

        func initializeTimeSync() {
            let uptime = ProcessInfo.processInfo.systemUptime
            let localTimestamp = Date().timeIntervalSince1970
            timeOffset = localTimestamp - uptime

            print("Time source: Local")
            print("Local UNIXTIME: \(localTimestamp)")
            print("Device Uptime: \(uptime)")
            print("Calculated Offset: \(timeOffset)")
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

        func resetCSVData() {
            let dataPath = documentsDirectory().appendingPathComponent("ARKitData.csv")
            let dataHeader = "Timestamp,Distance,DirectionX,DirectionY,DirectionZ,AccelerationX,AccelerationY,AccelerationZ,Features\n"

            measurementAnchor = nil
            isMeasuring = false
            frameIndex = 0

            resetIMUCSVData()

            do {
                try dataHeader.write(
                    to: dataPath,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                print("Failed to reset CSV file")
                print("\(error)")
            }
        }

        private func beginIMURecording() {
            imuWriteQueue.sync {
                isIMURecording = true
            }
        }

        private func resetIMUCSVData() {
            imuWriteQueue.sync {
                isIMURecording = false
                closeIMUFiles()

                rawAccelerometerFileHandle = createIMUFile(
                    fileName: "RawAccelerometer.csv",
                    header: "SensorTimestamp,Timestamp,RawAccelerationX_G,RawAccelerationY_G,RawAccelerationZ_G,RawAccelerationX_m_s2,RawAccelerationY_m_s2,RawAccelerationZ_m_s2\n"
                )

                rawGyroscopeFileHandle = createIMUFile(
                    fileName: "RawGyroscope.csv",
                    header: "SensorTimestamp,Timestamp,RawRotationRateX_rad_s,RawRotationRateY_rad_s,RawRotationRateZ_rad_s\n"
                )

                deviceMotionFileHandle = createIMUFile(
                    fileName: "DeviceMotion.csv",
                    header: "SensorTimestamp,Timestamp,GravityX_G,GravityY_G,GravityZ_G,UserAccelerationX_G,UserAccelerationY_G,UserAccelerationZ_G,UserAccelerationX_m_s2,UserAccelerationY_m_s2,UserAccelerationZ_m_s2,RotationRateX_rad_s,RotationRateY_rad_s,RotationRateZ_rad_s,QuaternionX,QuaternionY,QuaternionZ,QuaternionW,Roll_rad,Pitch_rad,Yaw_rad,AttitudeReferenceFrame\n"
                )
            }
        }

        private func createIMUFile(
            fileName: String,
            header: String
        ) -> FileHandle? {
            let path = documentsDirectory().appendingPathComponent(fileName)

            do {
                try header.write(
                    to: path,
                    atomically: true,
                    encoding: .utf8
                )

                let fileHandle = try FileHandle(forWritingTo: path)
                try fileHandle.seekToEnd()
                return fileHandle
            } catch {
                print("Failed to create \(fileName)")
                print("\(error)")
                return nil
            }
        }

        private func appendIMULine(
            _ line: String,
            to fileHandle: FileHandle?
        ) {
            guard let fileHandle = fileHandle,
                  let data = line.data(using: .utf8) else {
                return
            }

            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                print("Failed to append IMU data")
                print("\(error)")
            }
        }

        private func synchronizeIMUFiles() {
            try? rawAccelerometerFileHandle?.synchronize()
            try? rawGyroscopeFileHandle?.synchronize()
            try? deviceMotionFileHandle?.synchronize()
        }

        private func closeIMUFiles() {
            synchronizeIMUFiles()

            try? rawAccelerometerFileHandle?.close()
            try? rawGyroscopeFileHandle?.close()
            try? deviceMotionFileHandle?.close()

            rawAccelerometerFileHandle = nil
            rawGyroscopeFileHandle = nil
            deviceMotionFileHandle = nil
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
