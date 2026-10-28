//
//  SettingsView.swift
//  Dobby
//
//  Created by mason on 10/28/26.
//

import SwiftUI

/// 설정 항목 확정 전까지 탭 진입 시 표시하는 안내 화면입니다.
struct SettingsView: View {
    var body: some View {
        ContentUnavailableView("설정 준비 중", systemImage: "gearshape.fill",
            description: Text("설정 기능은 추후 제공될 예정이에요."))
            .accessibilityIdentifier("settings.placeholder")
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
