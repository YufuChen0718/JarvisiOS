@preconcurrency import AVFoundation
import SwiftUI

/// Full-bleed live preview backed by the shared AVSampleBufferDisplayLayer that
/// CameraManager/FrameGrabber feed. This is more reliable across devices than
/// AVCaptureVideoPreviewLayer (which rendered black on some hardware here).
struct CameraPreview: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.attach(displayLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.attach(displayLayer)
    }

    final class PreviewView: UIView {
        private weak var attached: AVSampleBufferDisplayLayer?

        func attach(_ display: AVSampleBufferDisplayLayer) {
            guard attached !== display else { return }
            attached?.removeFromSuperlayer()
            display.frame = bounds
            display.videoGravity = .resizeAspectFill
            layer.addSublayer(display)
            attached = display
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attached?.frame = bounds
        }
    }
}
