import AmaiCore
import SwiftUI

/// 菜单栏应用入口。M0 只有状态占位与退出；采集控制在 M1 接入。
@main
struct AmaiApp: App {
    private let log = AmaiLog.logger("app")

    init() {
        log.info("Amai launched")
    }

    var body: some Scene {
        MenuBarExtra("Amai", systemImage: "circle.dotted") {
            Text("Amai · 未开始采集")
            Divider()
            Button("退出 Amai") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
