import AVFoundation
import CoreMotion
import Photos
import UIKit
import Vision

enum CoachState { case searching, adjusting, aligned, ready }

struct Suggestion: Codable {
    var label: String
    var box: [Double]      // x,y,w,h normalized, top-left origin
    var light: String
    var zoom: Double
    var tip: String
}

final class CameraModel: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {

    let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let photoOut = AVCapturePhotoOutput()
    private let q = DispatchQueue(label: "shotcoach.camera")
    private let motion = CMMotionManager()
    private let ciContext = CIContext()
    private let seq = VNSequenceRequestHandler()
    private var device: AVCaptureDevice?
    private var tracker: VNTrackObjectRequest?
    private var lastSent = Date.distantPast
    private var inFlight = false
    private var alignedSince: Date?
    private var smoothed: CGRect?
    private var zoomBase: CGFloat = 1

    @Published var box: CGRect?
    @Published var label = ""
    @Published var hint = "Point at something interesting"
    @Published var tip = ""
    @Published var state: CoachState = .searching
    @Published var tilt: Double = 0
    @Published var zoomDisplay: Double = 1

    var apiKey: String { UserDefaults.standard.string(forKey: "apiKey") ?? "" }

    // MARK: Setup
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            self.q.async { self.configure(); self.session.startRunning() }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            self?.tilt = atan2(g.x, -g.y) * 180 / .pi
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        guard let dev = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices.first,
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return }
        session.addInput(input)
        device = dev
        if dev.constituentDevices.count > 1, let f = dev.virtualDeviceSwitchOverVideoZoomFactors.first {
            zoomBase = CGFloat(truncating: f)
        }
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.setSampleBufferDelegate(self, queue: q)
        if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
        if session.canAddOutput(photoOut) { session.addOutput(photoOut) }
        for out in [videoOut as AVCaptureOutput, photoOut] {
            out.connection(with: .video)?.videoRotationAngle = 90
        }
        session.commitConfiguration()
        setZoom(1)
    }

    // MARK: Frames
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        if let t = tracker {
            try? seq.perform([t], on: pb, orientation: .up)
            if let obs = t.results?.first as? VNDetectedObjectObservation, obs.confidence > 0.3 {
                t.inputObservation = obs
                let b = obs.boundingBox
                update(CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            } else { tracker = nil; update(nil) }
        }
        if !inFlight, !apiKey.isEmpty, Date().timeIntervalSince(lastSent) > 2 {
            inFlight = true; lastSent = Date()
            analyze(pb)
        }
    }

    // MARK: Coaching logic
    private func update(_ raw: CGRect?) {
        guard let raw else {
            DispatchQueue.main.async { self.box = nil; self.state = .searching; self.hint = "Looking for a great shot…" }
            return
        }
        let r: CGRect
        if let s = smoothed {   // low-pass filter to stop jitter
            let a: CGFloat = 0.35
            r = CGRect(x: s.minX + (raw.minX - s.minX) * a, y: s.minY + (raw.minY - s.minY) * a,
                       width: s.width + (raw.width - s.width) * a, height: s.height + (raw.height - s.height) * a)
        } else { r = raw }
        smoothed = r
        // nearest rule-of-thirds intersection
        let tx: CGFloat = r.midX < 0.5 ? 1.0 / 3 : 2.0 / 3
        let ty: CGFloat = r.midY < 0.5 ? 1.0 / 3 : 2.0 / 3
        let dx = tx - r.midX, dy = ty - r.midY
        let ok = abs(dx) < 0.05 && abs(dy) < 0.05
        var parts: [String] = []
        if abs(dx) >= 0.05 { parts.append(dx > 0 ? "left" : "right") }   // subject must move right => pan phone left
        if abs(dy) >= 0.05 { parts.append(dy > 0 ? "up" : "down") }
        var st: CoachState = ok ? .aligned : .adjusting
        if ok {
            if alignedSince == nil { alignedSince = Date() }
            if Date().timeIntervalSince(alignedSince!) > 0.6 { st = .ready }
        } else { alignedSince = nil }
        let h = ok ? (tip.isEmpty ? "Framing your shot…" : tip) : "Move your phone " + parts.joined(separator: " & ")
        DispatchQueue.main.async {
            let was = self.state
            self.box = r; self.hint = h; self.state = st
            if st == .ready && was != .ready { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }

    func setZoom(_ display: Double) {
        guard let d = device else { return }
        let f = min(max(CGFloat(display) * zoomBase, d.minAvailableVideoZoomFactor), min(d.maxAvailableVideoZoomFactor, 10))
        do {
            try d.lockForConfiguration(); d.ramp(toVideoZoomFactor: f, withRate: 3); d.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomDisplay = Double(f / self.zoomBase) }
        } catch {}
    }

    // MARK: Vision model call
    private func analyze(_ pb: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pb)
        let s = 512 / ci.extent.width
        guard let jpg = ciContext.jpegRepresentation(of: ci.transformed(by: .init(scaleX: s, y: s)),
                                                     colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else { inFlight = false; return }
        let prompt = """
        You are a photography coach looking at a live camera frame. Pick the single best subject for a striking photo \
        (consider light, leading lines, symmetry, color). Reply with ONLY JSON, no markdown: \
        {"label":"2-4 words","box":[x,y,w,h],"light":"harsh|soft|golden|dim|flat","zoom":0.5-5,"tip":"max 6 words"}. \
        box is normalized 0-1 with top-left origin. zoom is the ideal camera zoom for this subject.
        """
        let body: [String: Any] = [
            "model": "claude-haiku-5-5", "max_tokens": 300,
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpg.base64EncodedString()]],
                ["type": "text", "text": prompt]]]]
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { self.inFlight = false }
            guard let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let c = (j["content"] as? [[String: Any]])?.first, var txt = c["text"] as? String else { return }
            txt = txt.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            guard let sug = try? JSONDecoder().decode(Suggestion.self, from: Data(txt.utf8)), sug.box.count == 4 else { return }
            let b = sug.box
            let obs = VNDetectedObjectObservation(boundingBox: CGRect(x: b[0], y: 1 - b[1] - b[3], width: b[2], height: b[3]))
            let t = VNTrackObjectRequest(detectedObjectObservation: obs)
            t.trackingLevel = .fast
            self.q.async { self.tracker = t; self.smoothed = nil }
            self.setZoom(sug.zoom)
            DispatchQueue.main.async { self.label = sug.label; self.tip = sug.tip.isEmpty ? sug.light + " light" : sug.tip }
        }.resume()
    }

    // MARK: Shutter
    func shoot() { photoOut.capturePhoto(with: AVCapturePhotoSettings(), delegate: self) }
    func photoOutput(_ o: AVCapturePhotoOutput, didFinishProcessingPhoto p: AVCapturePhoto, error: Error?) {
        guard let d = p.fileDataRepresentation(), let img = UIImage(data: d) else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
    }
}
