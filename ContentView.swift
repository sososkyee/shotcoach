import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView(); v.layer.session = session; v.layer.videoGravity = .resizeAspectFill; return v
    }
    func updateUIView(_ v: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
    }
}

struct ContentView: View {
    @StateObject private var cam = CameraModel()
    @AppStorage("apiKey") private var apiKey = ""
    @State private var showKey = false

    var tint: Color { cam.state == .adjusting || cam.state == .searching ? .yellow : .green }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                CameraPreview(session: cam.session)
                GeometryReader { g in
                    if let b = cam.box {
                        RoundedRectangle(cornerRadius: 10).stroke(tint, lineWidth: 3)
                            .frame(width: b.width * g.size.width, height: b.height * g.size.height)
                            .position(x: b.midX * g.size.width, y: b.midY * g.size.height)
                        Text(cam.label).font(.footnote.bold()).foregroundStyle(tint)
                            .padding(6).background(.black.opacity(0.5), in: Capsule())
                            .position(x: b.midX * g.size.width, y: min(b.maxY * g.size.height + 18, g.size.height - 12))
                    }
                    // thirds grid
                    Path { p in
                        for i in 1...2 {
                            let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                            p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: g.size.height))
                            p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: g.size.width, y: y))
                        }
                    }.stroke(.white.opacity(0.25), lineWidth: 0.5)
                    // horizon
                    Rectangle().fill(abs(cam.tilt) < 1.5 ? Color.green : Color.yellow)
                        .frame(width: 140, height: 2).rotationEffect(.degrees(-cam.tilt))
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit).clipped()

            Text(cam.hint).font(.headline).foregroundStyle(tint)

            HStack(spacing: 10) {
                ForEach([0.5, 1, 2, 5], id: \.self) { z in
                    Button(z == 0.5 ? ".5x" : "\(Int(z))x") { cam.setZoom(z) }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(abs(cam.zoomDisplay - z) < 0.05 ? Color.yellow.opacity(0.3) : Color.white.opacity(0.1), in: Capsule())
                }
            }
            HStack(spacing: 40) {
                Button { showKey = true } label: { Image(systemName: "key.fill").frame(width: 56, height: 56) }
                Button { cam.shoot() } label: {
                    Circle().strokeBorder(.white, lineWidth: 4).background(Circle().fill(.white).padding(8)).frame(width: 76, height: 76)
                }
                Color.clear.frame(width: 56, height: 56)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .onAppear { cam.start(); if apiKey.isEmpty { showKey = true } }
        .alert("Anthropic API key", isPresented: $showKey) {
            SecureField("sk-ant-…", text: $apiKey)
            Button("Save") {}
        } message: { Text("Stored on this device only.") }
    }
}
