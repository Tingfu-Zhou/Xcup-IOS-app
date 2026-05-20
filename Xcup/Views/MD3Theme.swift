//
//  MD3Theme.swift
//  Xcup
//
//  Material Design 3 tokens (colors, typography, shapes) and button styles
//  used by the home page to match the Android app's MD3 visual language.
//

import SwiftUI

// MARK: - Color tokens

extension Color {
    static let md3Primary              = Color("MD3Primary")
    static let md3OnPrimary            = Color("MD3OnPrimary")
    static let md3PrimaryContainer     = Color("MD3PrimaryContainer")
    static let md3OnPrimaryContainer   = Color("MD3OnPrimaryContainer")
    static let md3Secondary            = Color("MD3Secondary")
    static let md3SecondaryContainer   = Color("MD3SecondaryContainer")
    static let md3OnSecondaryContainer = Color("MD3OnSecondaryContainer")
    static let md3Tertiary             = Color("MD3Tertiary")
    static let md3TertiaryContainer    = Color("MD3TertiaryContainer")
    static let md3OnTertiaryContainer  = Color("MD3OnTertiaryContainer")
    static let md3Error                = Color("MD3Error")
    static let md3ErrorContainer       = Color("MD3ErrorContainer")
    static let md3OnErrorContainer     = Color("MD3OnErrorContainer")
    static let md3Background           = Color("MD3Background")
    static let md3OnBackground         = Color("MD3OnBackground")
    static let md3Surface              = Color("MD3Surface")
    static let md3OnSurface            = Color("MD3OnSurface")
    static let md3SurfaceVariant       = Color("MD3SurfaceVariant")
    static let md3OnSurfaceVariant     = Color("MD3OnSurfaceVariant")
    static let md3Outline              = Color("MD3Outline")
}

// MARK: - Typography

enum MD3Typography {
    static let headlineSmall = Font.system(size: 24, weight: .regular)
    static let titleMedium   = Font.system(size: 16, weight: .medium)
    static let bodySmall     = Font.system(size: 12, weight: .regular)
}

// MARK: - Shape

enum MD3Shape {
    static let buttonCornerRadius: CGFloat = 20
}

// MARK: - Filled button (primary action)

struct MD3FilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = isEnabled ? .md3Primary : .md3OnSurface.opacity(0.12)
        let fg: Color = isEnabled ? .md3OnPrimary : .md3OnSurface.opacity(0.38)

        configuration.label
            .font(MD3Typography.titleMedium)
            .foregroundColor(fg)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: MD3Shape.buttonCornerRadius, style: .continuous)
                    .fill(bg)
            )
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Filled tonal button (secondary action)

struct MD3FilledTonalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = isEnabled ? .md3SecondaryContainer : .md3OnSurface.opacity(0.12)
        let fg: Color = isEnabled ? .md3OnSecondaryContainer : .md3OnSurface.opacity(0.38)

        configuration.label
            .font(MD3Typography.titleMedium)
            .foregroundColor(fg)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: MD3Shape.buttonCornerRadius, style: .continuous)
                    .fill(bg)
            )
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Error filled button (destructive / recovery action)

struct MD3ErrorFilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = isEnabled ? .md3Error : .md3OnSurface.opacity(0.12)
        let fg: Color = isEnabled ? .md3OnPrimary : .md3OnSurface.opacity(0.38)

        configuration.label
            .font(MD3Typography.titleMedium)
            .foregroundColor(fg)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: MD3Shape.buttonCornerRadius, style: .continuous)
                    .fill(bg)
            )
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Bluetooth state helper

extension View {
    @ViewBuilder
    func applyBluetoothStyle(isConnected: Bool) -> some View {
        if isConnected {
            self.buttonStyle(MD3FilledButtonStyle())
        } else {
            self.buttonStyle(MD3FilledTonalButtonStyle())
        }
    }
}

// MARK: - Top app bar

struct MD3TopAppBar: View {
    let title: String

    init(_ title: String = "Xcup") {
        self.title = title
    }

    var body: some View {
        HStack {
            Text(title)
                .font(MD3Typography.headlineSmall)
                .foregroundColor(.md3OnSurface)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color.md3Surface)
    }
}
