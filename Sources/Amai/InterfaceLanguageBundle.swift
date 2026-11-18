import Foundation
import ObjectiveC
import os

/// 让界面语言在运行中直接切换，不需要重启。
///
/// `String(localized:)` 与 SwiftUI 的文字都向主 bundle 查找本地化文字，默认按进程启动时的语言解析。
/// 启动时把主 bundle 换成这个子类，所有查找都转到当前所选语言的 `.lproj`：选完语言后，界面重建一次就整体换成新语言。
///
/// 实测 `String(localized:)` 调用的是非公开的 `_localizedStringForKey:value:table:localizations:`，
/// 公开的两个入口也一并转发。将来系统不再经过这些入口时，界面退回按启动时的语言显示（即需要重启才生效），不会出错。
final class InterfaceLanguageBundle: Bundle, @unchecked Sendable {
    /// 当前界面语言的 `.lproj`；nil 时按系统默认查找。
    private static let selected = OSAllocatedUnfairLock<Bundle?>(uncheckedState: nil)

    /// 启动时调用一次。子类不加存储属性，替换类之后主 bundle 的其余行为不变。
    static func install() {
        if !(Bundle.main is InterfaceLanguageBundle) { object_setClass(Bundle.main, InterfaceLanguageBundle.self) }
    }

    /// 切换到 `localization`（例如 "en"、"ja"、"zh-Hans"）；App 里没有这种语言时按系统默认查找。
    static func use(_ localization: String) {
        let path = Bundle.main.path(forResource: localization, ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:))
        selected.withLockUnchecked { $0 = bundle }
    }

    private static func lookup(_ key: String, _ value: String?, _ table: String?) -> String? {
        guard let bundle = selected.withLockUnchecked({ $0 }) else { return nil }
        return bundle.localizedString(forKey: key, value: value, table: table)
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        Self.lookup(key, value, tableName) ?? super.localizedString(forKey: key, value: value, table: tableName)
    }

    @available(macOS 15.4, *)
    override func __localizedString(
        forKey key: String, value: String?, table tableName: String?, localizations: [String]
    ) -> String {
        Self.lookup(key, value, tableName)
            ?? super.__localizedString(forKey: key, value: value, table: tableName, localizations: localizations)
    }

    @objc(_localizedStringForKey:value:table:localizations:)
    private func privateLocalizedString(
        _ key: String, value: String?, table tableName: String?, localizations: [String]?
    ) -> String {
        if let found = Self.lookup(key, value, tableName) { return found }
        // 没有选定语言时交回系统原来的实现。
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, NSArray?) -> NSString
        let selector = #selector(privateLocalizedString(_:value:table:localizations:))
        guard let method = class_getInstanceMethod(Bundle.self, selector) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        return original(self, selector, key as NSString, value as NSString?, tableName as NSString?, localizations as NSArray?) as String
    }
}

import Observation
import SwiftUI

/// 当前界面语言，供各界面入口观察：语言变了就以新语言重建视图（`String(localized:)` 在重建时重新取值）。
@MainActor
@Observable
final class InterfaceLanguageState {
    static let shared = InterfaceLanguageState()

    private(set) var localization = ""

    /// 语言为当前界面语言，地区沿用系统（日期、数字格式不变）。
    var locale: Locale {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: localization)
        return Locale(components: components)
    }

    func apply(_ localization: String) {
        InterfaceLanguageBundle.use(localization)
        self.localization = localization
    }
}

/// 套在每个界面入口（菜单、主窗口、引导、设置、聊天面板）的最外层。
struct InterfaceLanguageScope: ViewModifier {
    @State private var language = InterfaceLanguageState.shared

    func body(content: Content) -> some View {
        content
            .environment(\.locale, language.locale)
            .id(language.localization)
    }
}

extension View {
    func followsInterfaceLanguage() -> some View { modifier(InterfaceLanguageScope()) }
}
