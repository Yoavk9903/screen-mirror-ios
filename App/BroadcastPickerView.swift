import SwiftUI
import ReplayKit

/// There is no SwiftUI-native way to start a Broadcast Upload Extension — Apple requires
/// going through RPSystemBroadcastPickerView (a tiny system-provided button that, when
/// tapped, shows the system's own "Start Broadcast" sheet). This wraps it for SwiftUI.
struct BroadcastPickerView: UIViewRepresentable {
    /// Must equal the Broadcast Extension's bundle identifier
    /// (see project.yml → BroadcastExtension → PRODUCT_BUNDLE_IDENTIFIER).
    let extensionBundleId = "com.screenmirror.sender.BroadcastExtension"

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = extensionBundleId
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
