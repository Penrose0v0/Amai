import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

/// Multi-line chat input wrapping NSTextView. SwiftUI's
/// `TextField(axis: .vertical)` doesn't let us distinguish plain Return
/// (submit) from Shift+Return (newline), so we drop down to AppKit.
///
/// The visible height is driven by SwiftUI `.frame(height:)` rather than by
/// NSScrollView's intrinsicContentSize — when an `NSViewRepresentable` only
/// exposes intrinsic size, SwiftUI tends to let the view fill all offered
/// vertical space, which made the input balloon to half the window.
struct ChatInputTextView: View {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .systemFont(ofSize: 13)
    var maxVisibleLines: Int = 6
    var onSubmit: () -> Void
    /// Called when the user pastes an image (⌘V) into the field.
    var onPasteImage: ((NSImage) -> Void)? = nil

    @State private var contentHeight: CGFloat = 0

    /// 2pt top + 2pt bottom — gives the text a hair of breathing room so
    /// the empty input matches the prior TextField's vertical bulk.
    private let verticalInset: CGFloat = 2

    private var lineHeight: CGFloat {
        ceil(font.boundingRectForFont.height)
    }
    private var minHeight: CGFloat { lineHeight + verticalInset * 2 }
    private var maxHeight: CGFloat {
        lineHeight * CGFloat(max(1, maxVisibleLines)) + verticalInset * 2
    }
    private var clampedHeight: CGFloat {
        min(maxHeight, max(minHeight, contentHeight))
    }

    var body: some View {
        Representable(
            text: $text,
            contentHeight: $contentHeight,
            placeholder: placeholder,
            font: font,
            verticalInset: verticalInset,
            onSubmit: onSubmit,
            onPasteImage: onPasteImage
        )
        .frame(height: clampedHeight)
    }

    private struct Representable: NSViewRepresentable {
        @Binding var text: String
        @Binding var contentHeight: CGFloat
        var placeholder: String
        var font: NSFont
        var verticalInset: CGFloat
        var onSubmit: () -> Void
        var onPasteImage: ((NSImage) -> Void)?

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none

            let tv = ChatInputNSTextView(frame: .zero)
            tv.delegate = context.coordinator
            tv.isRichText = false
            tv.allowsUndo = true
            tv.font = font
            tv.textColor = .labelColor
            tv.insertionPointColor = .labelColor
            tv.backgroundColor = .clear
            tv.drawsBackground = false
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainerInset = NSSize(width: 0, height: verticalInset)
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainer?.widthTracksTextView = true
            tv.autoresizingMask = [.width]
            tv.placeholderString = placeholder
            tv.onSubmit = onSubmit
            tv.onPasteImage = onPasteImage
            tv.string = text

            scroll.documentView = tv
            context.coordinator.textView = tv

            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                tv.window?.makeFirstResponder(tv)
                context.coordinator.reportHeight()
            }
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.parent = self
            guard let tv = scroll.documentView as? ChatInputNSTextView else { return }
            if tv.string != text {
                tv.string = text
            }
            if tv.placeholderString != placeholder {
                tv.placeholderString = placeholder
            }
            if tv.font != font {
                tv.font = font
            }
            tv.onSubmit = onSubmit
            tv.onPasteImage = onPasteImage
            DispatchQueue.main.async {
                context.coordinator.reportHeight()
            }
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: Representable
            weak var textView: ChatInputNSTextView?

            init(_ parent: Representable) { self.parent = parent }

            func textDidChange(_ notification: Notification) {
                guard let tv = notification.object as? NSTextView else { return }
                parent.text = tv.string
                reportHeight()
            }

            func reportHeight() {
                guard let tv = textView,
                      let lm = tv.layoutManager,
                      let tc = tv.textContainer else { return }
                lm.ensureLayout(for: tc)
                let used = ceil(lm.usedRect(for: tc).height)
                let h = used + tv.textContainerInset.height * 2
                if abs(parent.contentHeight - h) > 0.5 {
                    parent.contentHeight = h
                }
            }
        }
    }
}

/// NSTextView with explicit Return-key handling and a placeholder string.
final class ChatInputNSTextView: NSTextView {
    var placeholderString: String? {
        didSet { needsDisplay = true }
    }
    var onSubmit: (() -> Void)?
    var onPasteImage: ((NSImage) -> Void)?

    private static let log = Logger(subsystem: "com.eira.app", category: "paste")

    // ⌘V: if the clipboard holds an image, attach it instead of pasting text.
    override func paste(_ sender: Any?) {
        if let handler = onPasteImage, let image = Self.imageFromPasteboard() {
            handler(image)
            return
        }
        super.paste(sender)
    }

    /// Pull an image off the pasteboard. Tries the direct image object, then
    /// brute-forces every data type on every item (decoding whatever bytes are
    /// an image — WeChat and friends use nonstandard type names), then an image
    /// file URL. Logs the available types on a miss so we can see what a source
    /// actually put on the clipboard.
    private static func imageFromPasteboard() -> NSImage? {
        let pb = NSPasteboard.general

        // An image file copied in Finder: read the actual file contents. This
        // must come first — the pasteboard also carries a generic file *icon*,
        // and the brute-force scan below would otherwise grab that icon as a
        // "valid" image (the JPG-document glyph, not the picture).
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        ) as? [URL], let url = urls.first,
           let image = NSImage(contentsOf: url), image.isValid {
            return image
        }

        // Direct image object (screenshots, "copy image").
        if let image = NSImage(pasteboard: pb), image.isValid { return image }

        // Brute-force any image bytes (nonstandard sources like WeChat).
        for item in pb.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type),
                   let image = NSImage(data: data), image.isValid {
                    return image
                }
            }
        }

        let types = (pb.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        log.warning("paste: no image found. pasteboard types: \(types, privacy: .public)")
        return nil
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘V with an image on the clipboard → attach it. Belt-and-suspenders with
        // the paste(_:) override, in case the text system routes ⌘V elsewhere.
        if mods == .command, event.charactersIgnoringModifiers == "v",
           let handler = onPasteImage, let image = Self.imageFromPasteboard() {
            handler(image)
            return
        }

        // keyCode 36 = Return, 76 = numeric keypad Enter
        let isReturn = (event.keyCode == 36 || event.keyCode == 76)
        if isReturn && !hasMarkedText() {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty {
                onSubmit?()
                return
            }
            if mods == .shift {
                insertText("\n", replacementRange: selectedRange())
                return
            }
            // Cmd / Option / Ctrl combos: fall through so SwiftUI keyboard
            // shortcuts (⌘↩ on the send button) still fire.
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty,
              let placeholder = placeholderString,
              !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        NSAttributedString(string: placeholder, attributes: attrs).draw(at: origin)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
