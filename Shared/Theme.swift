import SwiftUI

// MARK: - Color System

extension Color {
    static let ytRed        = Color(red: 1.0,  green: 0.09, blue: 0.27)   // #FF1745
    static let appBg        = Color(red: 0.047, green: 0.047, blue: 0.047) // #0C0C0C
    static let appSurface   = Color(red: 0.094, green: 0.094, blue: 0.094) // #181818
    static let appElevated  = Color(red: 0.141, green: 0.141, blue: 0.141) // #242424
    static let appBorder    = Color(white: 1.0, opacity: 0.06)
    static let appDim       = Color(white: 1.0, opacity: 0.55)
    static let appFaint     = Color(white: 1.0, opacity: 0.28)
    static let appGhost     = Color(white: 1.0, opacity: 0.12)
}

// MARK: - View Modifiers

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.appBorder, lineWidth: 0.5)
            )
    }
}

struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .semibold))
            .tracking(2.5)
            .foregroundStyle(Color.appFaint)
            .textCase(.uppercase)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
    func sectionHeader() -> some View { modifier(SectionHeaderStyle()) }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(configuration.isPressed ? Color.white.opacity(0.88) : .white)
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.5 : 0.8))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(tint.opacity(configuration.isPressed ? 0.1 : 0.07))
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(Color.appElevated.opacity(configuration.isPressed ? 0.5 : 1))
            .clipShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Reusable Components

struct StatusBadge: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(4)
            .background(color.opacity(0.15))
            .clipShape(Circle())
    }
}

struct ThumbnailView: View {
    let url: String?
    var size: CGFloat = 52
    var cornerRadius: CGFloat = 8

    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.appElevated
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3, weight: .light))
                    .foregroundStyle(Color.appFaint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
