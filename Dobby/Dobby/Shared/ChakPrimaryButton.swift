//
//  ChakPrimaryButton.swift
//  Dobby
//
//  Created by Jiwon Park on 10/21/26.
//

import SwiftUI

struct ChakPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .contentShape(Rectangle())
            .background(.brandMain)
            .cornerRadius(60)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct ChakPrimaryButton: View {
    let title: String
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
        .buttonStyle(ChakPrimaryButtonStyle())
    }
}

#Preview {
    VStack {
        ChakPrimaryButton(title: "플랫폼에 업로드하러 가기", action: {})
    }
}
