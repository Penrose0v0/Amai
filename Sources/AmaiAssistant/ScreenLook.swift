import AmaiCore
import Foundation

/// 用户要求"带上屏幕"时取一张截图。
///
/// 截图直接随消息发给模型；模型不能看图时不取截图，回答只依据上下文里的 OCR 文字。
/// 截图经感知层的 `LiveContextReading` 获取，受同一套隐私策略约束，不落盘。
public enum ScreenLook {
    public struct Result: Sendable, Equatable {
        public var images: [ChatImage] = []
        /// 读不到屏幕时给模型的说明。
        public var note: String?
    }

    public static func look(
        live: any LiveContextReading, scope: ScreenScope, modelSeesImages: Bool
    ) async -> Result {
        guard modelSeesImages else { return Result() }
        let image: ScreenImage
        do {
            image = try await live.screen(scope, maxAge: 2, maxHeight: 1080)
        } catch let error as LiveContextError {
            return Result(note: describe(error))
        } catch {
            return Result(note: "The screenshot could not be taken.")
        }
        return Result(images: [ChatImage(jpeg: image.jpeg, perceptualHash: image.perceptualHash)])
    }

    static func describe(_ error: LiveContextError) -> String {
        switch error {
        case .blocked(let reason):
            "The user asked to attach a screenshot, but the screen can't be read right now because of their privacy settings (\(reason)). Tell the user; do not guess what is on screen."
        case .screenRecordingDenied:
            "The user asked to attach a screenshot, but Amai does not have the Screen Recording permission. They can grant it in System Settings → Privacy & Security."
        case .unavailable:
            "The screenshot could not be taken."
        }
    }
}
