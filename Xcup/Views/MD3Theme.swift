//
//  MD3Theme.swift
//  Xcup
//
//  Material Design 3 tokens (colors, typography, shapes) and button styles
//  used by the home page to match the Android app's MD3 visual language.
//

import SwiftUI

// MARK: - Color tokens
// Color.md3Primary 等访问器由 Xcode 根据 Assets.xcassets 自动生成（GeneratedAssetSymbols.swift），无需手写扩展。

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
