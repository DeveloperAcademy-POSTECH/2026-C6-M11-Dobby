//
//  ExportRecord.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import Foundation
import SwiftData

/// 내보내기 한 건.

@Model
final class ExportRecord {
    @Attribute(.unique) var id: UUID
    var channelRaw: String
    var exportedAt: Date
    var succeeded: Bool
    /// 실패했을 때 사용자에게 보여줄 이유.
    var message: String?

    var garment: Garment?

    init(channel: ExportChannel, succeeded: Bool, message: String? = nil) {
        self.id = UUID()
        self.channelRaw = channel.rawValue
        self.exportedAt = .now
        self.succeeded = succeeded
        self.message = message
    }

    var channel: ExportChannel {
        get { ExportChannel(rawValue: channelRaw) ?? .instagram }
        set { channelRaw = newValue.rawValue }
    }
}

extension Garment {
    /// 이 채널로 이미 성공한 적이 있는지. 내보내기 화면의 체크 표시에 쓴다.
    func hasExported(to channel: ExportChannel) -> Bool {
        exports.contains { $0.channelRaw == channel.rawValue && $0.succeeded }
    }
}
