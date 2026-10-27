
import AVFoundation
import Vision
import ImageIO
import CoreVideo

/*
 PURPOSE:
 Open the iPhone's front camera, examine video frames, and identify
 possible signs of driver inattention.

 IMPORTANT:
 Camera frames are processed locally and are not saved or uploaded.
 */


// Uses the front camera and Vision to estimate driver attention.
// Camera frames are processed locally and are not saved or uploaded.
final class DAMSCameraMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // The preview and detector share this camera session.
    let session = AVCaptureSession()

    // ContentView supplies these callbacks.
    var onAlert: ((SafetyAlert) -> Void)?
    var onStatus: ((String) -> Void)?

    // Camera setup and frame processing use separate queues.
    private let sessionQueue = DispatchQueue(label: "DAMS.camera.session")
    private let frameQueue = DispatchQueue(label: "DAMS.camera.frames")

    // The following detection state is accessed by frameQueue only.
    private var lastProcessedFrameTime: TimeInterval = 0
    private var eyesClosedSince: TimeInterval?
    private var lookingAwaySince: TimeInterval?
    private var faceMissingSince: TimeInterval?
    private var lastAlertTime: [SafetyAlert: TimeInterval] = [:]

    // Initial tuning values. These must be tested, not assumed correct.
    private let minimumFrameInterval: TimeInterval = 0.10
    private let closedEyeRatioThreshold: CGFloat = 0.16
    private let closedEyeAlertDuration: TimeInterval = 1.2
    private let turnedHeadThresholdRadians: Double = 0.35
    private let turnedHeadAlertDuration: TimeInterval = 2.0
    private let missingFaceAlertDuration: TimeInterval = 3.0
    private let alertCooldown: TimeInterval = 30.0

    private var isConfigured = false

    // Ask iOS for camera permission before setting up the camera.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartCamera()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }

                if granted {
                    self.configureAndStartCamera()
                } else {
                    self.reportStatus("ERROR: Camera permission denied. Allow camera access in iPhone Settings.")
                }
            }

        case .denied, .restricted:
            reportStatus("ERROR: Allow camera access in iPhone Settings")

        @unknown default:
            reportStatus("ERROR: Unknown camera permission status")
        }
    }

    // Stop processing and release the camera.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.session.isRunning {
                self.session.stopRunning()
            }

            self.reportStatus("DAMS camera stopped")
        }
    }

    // Configure the camera once, then start its session.
    private func configureAndStartCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                guard self.configureCamera() else { return }
            }

            if !self.session.isRunning {
                // Reset temporary detection state before restarting the camera.
                self.frameQueue.sync {
                   self.lastProcessedFrameTime = 0
                   self.eyesClosedSince = nil
                   self.lookingAwaySince = nil
                   self.faceMissingSince = nil
               }
                self.session.startRunning()
            }

            self.reportStatus("DAMS camera running")
        }
    }

    // Connect the front camera to the session and configure video delivery.
    private func configureCamera() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
        }

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
            reportStatus("Front camera not found")
            return false
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)

            guard session.canAddInput(input) else {
                reportStatus("Could not add camera input")
                return false
            }

            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]

            output.setSampleBufferDelegate(self, queue: frameQueue)

            guard session.canAddOutput(output) else {
                reportStatus("Could not add camera output")
                return false
            }

            session.addOutput(output)
            isConfigured = true
            return true

        } catch {
            reportStatus("Camera setup failed: \(error.localizedDescription)")
            return false
        }
    }

    // Apple's camera framework calls this for each available frame.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime

        // Avoid processing every camera frame. This targets at most
        // approximately 10 frames per second.
        guard now - lastProcessedFrameTime >= minimumFrameInterval else {
            return
        }

        lastProcessedFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,
            options: [:]
        )

        do {
            try handler.perform([request])

            let faces = request.results ?? []

            // If several faces are visible, use the largest detected face.
            guard let face = faces.max(by: {
                $0.boundingBox.width * $0.boundingBox.height <
                $1.boundingBox.width * $1.boundingBox.height
            }) else {
                processMissingFace(at: now)
                return
            }

            faceMissingSince = nil
            processVisibleFace(face, at: now)

        } catch {
            reportStatus("Vision processing failed")
        }
    }

    // Track how long no face has been detected.
    private func processMissingFace(at now: TimeInterval) {
        eyesClosedSince = nil
        lookingAwaySince = nil

        if faceMissingSince == nil {
            faceMissingSince = now
        }

        guard let start = faceMissingSince,
              now - start >= missingFaceAlertDuration else {
            return
        }

        emit(.faceNotVisible, at: now)
    }

    // Estimate eye openness by comparing the eye landmark region's height
    // with its width. This is a rough heuristic, not a validated measurement.
    private func eyeAspectRatio(
        _ eye: VNFaceLandmarkRegion2D
    ) -> CGFloat {
        let points = eye.normalizedPoints

        guard points.count >= 4 else {
            return 1.0
        }

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0

        let width = maxX - minX
        let height = maxY - minY

        return height / max(width, 0.001)
    }
    
    
    // Analyze a detected face to estimate eye closure and head rotation.
    // These are rough indicators, not reliable proof of drowsiness or distraction.
    private func processVisibleFace(
        _ face: VNFaceObservation,
        at now: TimeInterval
    ) {
        // Eye-region height divided by width is a rough shape estimate.
        // It is not a clinically validated eye-closure measurement.
        if let leftEye = face.landmarks?.leftEye,
           let rightEye = face.landmarks?.rightEye {

            let leftRatio = eyeAspectRatio(leftEye)
            let rightRatio = eyeAspectRatio(rightEye)

            let bothEyesAppearClosed =
                leftRatio < closedEyeRatioThreshold &&
                rightRatio < closedEyeRatioThreshold

            if bothEyesAppearClosed {
                if eyesClosedSince == nil {
                    eyesClosedSince = now
                }

                if let start = eyesClosedSince,
                   now - start >= closedEyeAlertDuration {
                    emit(.drowsy, at: now)
                }
            } else {
                eyesClosedSince = nil
            }
        } else {
            // If Vision cannot find both eyes, don't guess that they
            // are closed.
            eyesClosedSince = nil
        }

        // Yaw estimates head rotation, not the exact direction of gaze.
        if let yaw = face.yaw?.doubleValue,
           abs(yaw) >= turnedHeadThresholdRadians {

            if lookingAwaySince == nil {
                lookingAwaySince = now
            }

            if let start = lookingAwaySince,
               now - start >= turnedHeadAlertDuration {
                emit(.distracted, at: now)
            }
        } else {
            lookingAwaySince = nil
        }
    }

    // Prevent one persistent condition from speaking repeatedly.
    private func emit(_ alert: SafetyAlert, at now: TimeInterval) {
        if let lastTime = lastAlertTime[alert],
           now - lastTime < alertCooldown {
            return
        }

        lastAlertTime[alert] = now

        DispatchQueue.main.async { [weak self] in
            self?.onAlert?(alert)
        }
    }

    private func reportStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }
}
