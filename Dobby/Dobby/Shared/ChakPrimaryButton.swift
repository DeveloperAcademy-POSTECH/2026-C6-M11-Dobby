//
//  ChakPrimaryButton.swift
//  Dobby
//
//  Created by Jiwon Park on 10/21/26.
//

import SwiftUI

enum ChakPrimaryButtonVariant {
    case solid
    case tonal
}

struct ChakPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let variant: ChakPrimaryButtonVariant

    func makeBody(configuration: Configuration) -> some View {
        let colors = colors(isPressed: configuration.isPressed)

        configuration.label
            .font(.headline)
            .foregroundStyle(colors.foreground)
            .tint(colors.foreground)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .contentShape(Capsule())
            .background(colors.background, in: Capsule())
    }

    private func colors(isPressed: Bool) -> (background: Color, foreground: Color) {
        switch (variant, isEnabled, isPressed) {
        case (.solid, false, _):
            return (Color("BrandNeutral400"), Color("BrandNeutral100"))
        case (.solid, true, true):
            return (Color("BrandPrimary200"), Color("BrandNeutralWhite"))
        case (.solid, true, false):
            return (Color("BrandPrimary100"), Color("BrandNeutralWhite"))
        case (.tonal, false, _):
            return (Color("BrandNeutral100"), Color("BrandNeutral400"))
        case (.tonal, true, true):
            return (Color("BrandNeutral200"), Color("BrandNeutralBlack"))
        case (.tonal, true, false):
            return (Color("BrandNeutral100"), Color("BrandNeutral900"))
        }
    }
}

struct ChakPrimaryButton: View {
    let title: String
    var variant = ChakPrimaryButtonVariant.solid
    var isLoading = false
    var showsCompletion = false
    let action: @MainActor () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if showsCompletion {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
        }
        .buttonStyle(ChakPrimaryButtonStyle(variant: variant))
    }
}

#Preview {
    VStack(spacing: 16) {
        ChakPrimaryButton(title: "Solid", action: {})
        ChakPrimaryButton(title: "Solid Disabled", action: {})
            .disabled(true)
        ChakPrimaryButton(title: "Tonal", variant: .tonal, action: {})
        ChakPrimaryButton(title: "Tonal Disabled", variant: .tonal, action: {})
            .disabled(true)
    }
    .padding()
}
