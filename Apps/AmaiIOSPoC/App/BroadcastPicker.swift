import ReplayKit
import SwiftUI

/// 系统的广播选择器按钮。开始广播必须由用户在系统界面里确认，App 不能自己开始。
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        // 只列出本 PoC 的扩展；PoC 不采集麦克风。
        view.preferredExtension = Bundle.main.object(forInfoDictionaryKey: "AmaiBroadcastExtension") as? String
        view.showsMicrophoneButton = false
        return view
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
