import SwiftUI
import ReplayKit

/// There is no SwiftUI-native way to start a Broadcast Upload Extension — Apple requires
/// going through RPSystemBroadcastPickerView (a system-provided button that, when tapped,
/// shows the system's own "Start Broadcast" sheet).
///
/// That system button draws its own tiny icon, and in practice it can end up invisible or
/// zero-sized inside SwiftUI. So we show our own clearly visible "start broadcast" button
/// and lay the real (nearly transparent) system picker on top of it, stretched to fill it,
/// so a real tap on our button is a real tap on Apple's.
struct BroadcastPickerView: View {
    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.blue)
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("התחל שידור מסך")
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)

            PickerOverlay()
        }
        .frame(width: 240, height: 52)
    }
}

private struct PickerOverlay: UIViewRepresentable {
    /// Must equal the Broadcast Extension's bundle identifier
    /// (see project.yml → BroadcastExtension → PRODUCT_BUNDLE_IDENTIFIER).
    static let extensionBundleId = "com.screenmirror.sender.BroadcastExtension"

    func makeUIView(context: Context) -> PickerContainer {
        PickerContainer()
    }

    func updateUIView(_ uiView: PickerContainer, context: Context) {}
}

private final class PickerContainer: UIView {
    private let picker = RPSystemBroadcastPickerView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        picker.preferredExtension = PickerOverlay.extensionBundleId
        picker.showsMicrophoneButton = false
        picker.alpha = 0.02 // visually hidden, but (unlike alpha 0) still receives touches
        addSubview(picker)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
        // The system picker contains one UIButton; make it fill the whole area.
        for case let button as UIButton in picker.subviews {
            button.frame = picker.bounds
        }
    }
}
