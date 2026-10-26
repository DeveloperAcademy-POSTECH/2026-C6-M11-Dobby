//
//  HomeTypography.swift
//  Dobby
//
//  Created by mason on 10/26/26.
//

import CoreText
import SwiftUI

enum HomeTypography {
    // 홈에서 사용하는 글꼴만 한 번 등록해 프로젝트·Info.plist 설정 변경을 피합니다.
    static let guidance: Font = {
        if let url = Bundle.main.url(forResource: "Pretendard-Bold", withExtension: "otf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return .custom("Pretendard-Bold", size: 20, relativeTo: .title3)
    }()
}
