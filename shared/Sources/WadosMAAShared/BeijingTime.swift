//
//  BeijingTime.swift
//  WadosMAAShared
//
//  后端写的时间都是带时区的 ISO8601，界面一律按北京时间显示。
//

import Foundation

public enum BeijingTime {
    public static let zone = TimeZone(identifier: "Asia/Shanghai")!

    public static func parseISO(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// 「08:05」。
    public static func clock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
