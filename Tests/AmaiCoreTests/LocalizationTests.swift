import Foundation
import Testing
@testable import AmaiCore

/// 界面本地化的静态检查：String Catalog（Resources/Localizable.xcstrings）与权限说明（Resources/InfoPlist）。
/// 运行时的排版与截断需要在真机界面中检查，这里只保证翻译齐全、占位符一致。
@Suite("Interface localization")
struct LocalizationTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let translations = ["en", "ja"]

    /// 键 → (语言 → 译文)。shouldTranslate 为 false 的键（品牌名、OpenAI 规定的英文按钮文字）不在其中。
    static func catalog() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "zh-Hans")
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        var result: [String: [String: String]] = [:]
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            var values: [String: String] = [:]
            for (language, localization) in localizations {
                guard let unit = localization["stringUnit"] as? [String: String], unit["state"] == "translated",
                      let value = unit["value"]
                else { continue }
                values[language] = value
            }
            result[key] = values
        }
        return result
    }

    /// 占位符的类型序列（按位置参数排序）：`%1$@ %2$lld` 与 `%@ %lld` 相同。
    static func placeholders(_ text: String) -> [String] {
        let pattern = /%(?:(\d+)\$)?(lld|ld|lu|llu|lf|d|u|@|f|g)/
        var positional: [(Int, String)] = []
        for (index, match) in text.replacing("%%", with: "").matches(of: pattern).enumerated() {
            positional.append((match.output.1.flatMap { Int($0) } ?? index + 1, String(match.output.2)))
        }
        return positional.sorted { $0.0 < $1.0 }.map(\.1)
    }

    @Test("every interface string has an English and a Japanese translation")
    func translationsComplete() throws {
        let catalog = try Self.catalog()
        #expect(catalog.count > 400)
        for language in Self.translations {
            let missing = catalog.filter { $0.value[language]?.isEmpty ?? true }.keys.sorted()
            #expect(missing.isEmpty, "missing \(language): \(missing)")
        }
    }

    @Test("translations keep the source's placeholders")
    func placeholdersMatch() throws {
        for (key, values) in try Self.catalog() {
            let source = values["zh-Hans"] ?? key
            for language in Self.translations {
                guard let value = values[language] else { continue }
                #expect(Self.placeholders(value) == Self.placeholders(source), "\(language): \(key) → \(value)")
            }
        }
    }

    @Test("Japanese text contains no Simplified Chinese characters")
    func japaneseIsNotChinese() throws {
        // 只在简体中文中使用、日文写法不同的常用字（日文分别写作 們 這 説 時 間 記 憶 録 為 …）。
        let simplifiedOnly = Set("们这说时间记忆录为没还从让给发现关开据处条键请输选择应显载档块获该结确认删设动务线统级网读页")
        for (key, values) in try Self.catalog() {
            guard let ja = values["ja"] else { continue }
            let found = ja.filter { simplifiedOnly.contains($0) }
            #expect(found.isEmpty, "\(key) → \(ja)")
        }
    }

    @Test("permission descriptions exist for every interface language")
    func infoPlistStrings() throws {
        let plist = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        let languages = try #require(info["CFBundleLocalizations"] as? [String])
        #expect(Set(languages) == ["zh-Hans", "en", "ja"])

        var keySets: [String: Set<String>] = [:]
        for language in languages {
            let url = Self.root.appendingPathComponent("Resources/InfoPlist/\(language).lproj/InfoPlist.strings")
            let strings = try #require(NSDictionary(contentsOf: url) as? [String: String], "\(language)")
            #expect(strings.values.allSatisfy { !$0.isEmpty })
            keySets[language] = Set(strings.keys)
        }
        #expect(Set(keySets.values).count == 1, "\(keySets)")
    }

    @Test("language tags map to the three supported languages")
    func languageTags() {
        #expect(MemoryLanguage(languageTag: "ja") == .ja)
        #expect(MemoryLanguage(languageTag: "ja-JP") == .ja)
        #expect(MemoryLanguage(languageTag: "ja_JP") == .ja)
        #expect(MemoryLanguage(languageTag: "en") == .en)
        #expect(MemoryLanguage(languageTag: "en-GB") == .en)
        #expect(MemoryLanguage(languageTag: "zh-Hans") == .zhHans)
        #expect(MemoryLanguage(languageTag: "zh-Hans-JP") == .zhHans)
        #expect(MemoryLanguage(languageTag: "zh-CN") == .zhHans)
        #expect(MemoryLanguage(languageTag: "zh-Hant") == nil)
        #expect(MemoryLanguage(languageTag: "zh-Hant-TW") == nil)
        #expect(MemoryLanguage(languageTag: "zh-TW") == nil)
        #expect(MemoryLanguage(languageTag: "fr-FR") == nil)
        #expect(MemoryLanguage(languageTag: "") == nil)
    }
}
