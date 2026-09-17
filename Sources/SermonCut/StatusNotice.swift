import SwiftUI

enum NoticeTone { case normal, warning, error }
enum ProjectArea: Hashable { case source, trim, subtitles, bumpers, export }
enum YouTubeArea: Hashable { case account, playlists, thumbnail, upload }
struct ProjectNotice {
    let id = UUID()
    let text: String
    let tone: NoticeTone
    var isSubtitleTimingConfirmation = false
}

struct StatusNotice: View {
    let text: String
    var tone: NoticeTone = .normal
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var verticalAlignment: VerticalAlignment = .top
    private var color: Color {
        switch tone { case .normal: .green; case .warning: .orange; case .error: .red }
    }
    private var symbol: String {
        switch tone {
        case .normal: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }
    var body: some View {
        if !text.isEmpty {
            HStack(alignment: verticalAlignment, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(text).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
                if let actionTitle, let action {
                    SermonClipButton(actionTitle, systemImage: "folder", action: action)
                        .buttonStyle(SermonClipStandardPrimaryStyle())
                        .fixedSize()
                }
            }
            .padding(12)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.25)))
        }
    }
}

/// Shared label typography, retaining each button's native style and role.
struct SermonClipButton<Label: View>: View {
    var role: ButtonRole?
    var action: () -> Void
    var label: Label

    init(role: ButtonRole? = nil, action: @escaping () -> Void,
         @ViewBuilder label: () -> Label) {
        self.role = role
        self.action = action
        self.label = label()
    }

    var body: some View {
        SwiftUI.Button(role: role, action: action) {
            label.textCase(.uppercase).tracking(1).lineLimit(1)
        }
        .handCursor()
    }
}

enum SermonClipButtonKind { case largePrimary, primary, secondary, destructive, link, trimStart, trimEnd }

enum SermonClipPalette {
    static let secondaryFill = Color(red: 1, green: 245.0 / 255, blue: 233.0 / 255)
    static let hoverOverlayOpacity = 0.04
}

struct SermonClipUnifiedButtonStyle: ButtonStyle {
    var kind: SermonClipButtonKind = .secondary
    func makeBody(configuration: Configuration) -> some View {
        SermonClipStyledButtonBody(kind: kind, configuration: configuration)
    }
}

private struct SermonClipStyledButtonBody: View {
    let kind: SermonClipButtonKind
    let configuration: ButtonStyleConfiguration
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }

    var body: some View {
        let destructive = kind == .destructive || (kind == .secondary && configuration.role == .destructive)
        let primary = kind == .primary || kind == .largePrimary
        let link = kind == .link
        let trim = kind == .trimStart || kind == .trimEnd
        let fullWidth = kind == .largePrimary || trim
        let fill = !trim && !destructive && !primary ? SermonClipPalette.secondaryFill : color(kind == .trimStart ? 0x348559 : kind == .trimEnd ? 0xdb383c : destructive ? 0xd71e04 : 0xffd49e)
        let border = trim ? fill : color(destructive ? 0xbc1603 : primary ? 0xefc794 : 0xf6ede1)
        configuration.label
            .foregroundStyle(link ? Color.primary : destructive || trim ? Color.white : Color.black)
            .lineLimit(1)
            .fixedSize(horizontal: !fullWidth, vertical: true)
            .padding(.horizontal, link ? 0 : 12)
            .padding(.vertical, link ? 0 : 8)
            .frame(maxWidth: fullWidth ? .infinity : nil,
                   minHeight: link ? nil : kind == .largePrimary ? 64 : 32)
            .background {
                if !link {
                    RoundedRectangle(cornerRadius: 8).fill(fill)
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(hovering && isEnabled ? SermonClipPalette.hoverOverlayOpacity : 0))
                }
            }
            .overlay {
                if !link { RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.35 : activeState == .inactive ? 0.55 : configuration.isPressed ? 0.75 : 1)
            .onHover { hovering = $0 }
    }
}

struct SermonClipStandardPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SermonClipUnifiedButtonStyle(kind: .primary).makeBody(configuration: configuration)
    }
}
struct SermonClipLargePrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SermonClipUnifiedButtonStyle(kind: .largePrimary).makeBody(configuration: configuration)
    }
}
struct SermonClipSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SermonClipUnifiedButtonStyle(kind: .secondary).makeBody(configuration: configuration)
    }
}
struct SermonClipDestructiveStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SermonClipUnifiedButtonStyle(kind: .destructive).makeBody(configuration: configuration)
    }
}
struct SermonClipLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SermonClipUnifiedButtonStyle(kind: .link).makeBody(configuration: configuration)
    }
}

extension SermonClipButton where Label == Text {
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(verbatim: title.uppercased()) }
    }
}

extension SermonClipButton where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.init(action: action) {
            SwiftUI.Label { Text(verbatim: title.uppercased()) } icon: { Image(systemName: systemImage) }
        }
    }
}

struct WorkflowSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            content()
        }
        .modifier(WorkflowCardStyle())
    }
}

/// Shared container for project steps and bumper-library categories.
struct WorkflowCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

/// Shared input styling keeps the macOS defaults consistent throughout the app.
extension View {
    func sermonClipDropdownStyle() -> some View {
        self.controlSize(.large).frame(minHeight: 32).handCursor()
    }

    func sermonClipInputStyle(onDarkSurface: Bool = false) -> some View {
        self
            .textFieldStyle(.plain)
            .font(.body)
            .controlSize(.large)
            .padding(10)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .modifier(SermonClipFieldBackground(alternate: onDarkSurface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    func sermonClipTextEditorStyle(onDarkSurface: Bool = false, minimumHeight: CGFloat = 240) -> some View {
        self
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .font(.body)
            .padding(10)
            .frame(minHeight: minimumHeight)
            .modifier(SermonClipFieldBackground(alternate: onDarkSurface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    func handCursor() -> some View {
        onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

private struct SermonClipFieldBackground: ViewModifier {
    let alternate: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shade: Double = colorScheme == .dark ? (alternate ? 0.22 : 0.17) : (alternate ? 1 : 0.96)
        content.background(Color(white: shade), in: RoundedRectangle(cornerRadius: 8))
    }
}
