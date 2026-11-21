//
//  Palette.swift
//  Wado's MAA (iOS)
//
//  设计稿 E 七段的颜色。流程七段各有固定颜色，深浅色都过 4.5:1。
//

import SwiftUI
import UIKit

enum Palette {
    static let background = dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let card = dynamic(light: 0xF2F2F7, dark: 0x1C1C1E)
    static let raised = dynamic(light: 0xE3E3E8, dark: 0x3A3A3E)
    static let secondary = dynamic(light: 0x636366, dark: 0xA1A1A8)
    static let hairline = dynamic(light: 0x3C3C43, lightAlpha: 0.2, dark: 0xFFFFFF, darkAlpha: 0.14)
    static let ghost = dynamic(light: 0x3C3C43, lightAlpha: 0.11, dark: 0xFFFFFF, darkAlpha: 0.13)

    static let blue = dynamic(light: 0x0A64C9, dark: 0x5AA9FF)
    static let red = dynamic(light: 0xC92A22, dark: 0xFF6A61)
    static let orange = dynamic(light: 0xC2410C, dark: 0xFF8A3D)
    static let green = dynamic(light: 0x177A3A, dark: 0x4ADE80)
    static let pink = dynamic(light: 0xC41E68, dark: 0xFF6FA8)
    static let amber = dynamic(light: 0x8F6200, dark: 0xFFC83D)
    static let violet = dynamic(light: 0x6D3FD1, dark: 0xB79CFF)
    static let teal = dynamic(light: 0x00786F, dark: 0x2DD4BF)
    static let accent = dynamic(light: 0x0A64C9, dark: 0x0A84FF)
    static let stop = dynamic(light: 0xD70015, dark: 0xE5252A)

    private static func dynamic(
        light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? color(dark, darkAlpha) : color(light, lightAlpha)
        })
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}

/// 日常的七段：顺序、颜色、图标和短名都固定。
enum DailyStep: String, CaseIterable, Identifiable {
    case startUp = "StartUp"
    case annihilation = "Annihilation"
    case fight = "Fight"
    case infrast = "Infrast"
    case recruit = "Recruit"
    case mall = "Mall"
    case award = "Award"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startUp: "启动游戏"
        case .annihilation: "剿灭"
        case .fight: "刷理智"
        case .infrast: "基建"
        case .recruit: "公招"
        case .mall: "商店"
        case .award: "领奖"
        }
    }

    var symbol: String {
        switch self {
        case .startUp: "power"
        case .annihilation: "scope"
        case .fight: "bolt"
        case .infrast: "building.2"
        case .recruit: "person.badge.plus"
        case .mall: "storefront"
        case .award: "gift"
        }
    }

    var color: Color {
        switch self {
        case .startUp: Palette.blue
        case .annihilation: Palette.red
        case .fight: Palette.orange
        case .infrast: Palette.green
        case .recruit: Palette.pink
        case .mall: Palette.amber
        case .award: Palette.violet
        }
    }
}
