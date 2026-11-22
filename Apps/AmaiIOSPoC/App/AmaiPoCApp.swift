import SwiftUI

@main
struct AmaiPoCApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let log = EventLog(process: "app")

    var body: some Scene {
        WindowGroup {
            ContentView(log: log)
        }
        .onChange(of: scenePhase) { _, phase in
            // 主 App 进入后台 / 回到前台的时刻，用来对照采集是否受影响。
            let name = switch phase {
            case .active: "appActive"
            case .inactive: "appInactive"
            case .background: "appBackground"
            @unknown default: "appUnknownPhase"
            }
            log.write(name, DeviceStats.snapshot())
        }
    }
}
