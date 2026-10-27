
import SwiftUI
import AVFoundation
import UIKit

/*
     PURPOSE:
     Display the iPhone camera feed inside our existing app.

     IMPORTS:
     - SwiftUI: Builds the app's user interface.
     - AVFoundation: Provides Apple's camera APIs.
     - UIKit: Provides UIView, the underlying view used for the camera preview.

     IMPORTANT:
     This file only displays the camera feed on the screen.
     Another part of the app will manage the camera and process its
     video to detect driver inattention and trigger alerts.
 */


struct DAMSPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    // We create our custom UIKit view, connect the camera session,
    // configure how the video fills the screen, and return the view.
    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        
        // Connect the preview layer to the camera session as that supplies the video
        view.videoPreviewLayer.session = session
        
        // Fill the available space with video
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        return view
    }

    // called when the existing view needs to reflect updated data.
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        
        // The camera session is managed by DAMSCameraMonitor.
        // SwiftUI does not need to start or stop it here.
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }
}

// A UIView whose main layer is Apple's camera preview layer.
final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
