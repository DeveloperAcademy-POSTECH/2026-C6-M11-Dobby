//
//  ChakPrimaryButton.swift
//  Dobby
//
//  Created by Jiwon Park on 10/21/26.
//

import SwiftUI

struct ChakPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .contentShape(Rectangle())
            .background(.brandMain)
            .cornerRadius(60)
    }
}

struct ChakPrimaryButton: View {
    let title: String
    let action: @MainActor () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(ChakPrimaryButtonStyle())
    }
}

#Preview {
    VStack {
        ChakPrimaryButton(title: "플랫폼에 업로드하러 가기", action: {})
    }
}
