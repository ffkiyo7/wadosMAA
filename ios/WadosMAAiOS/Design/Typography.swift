//
//  Typography.swift
//  Wado's MAA (iOS)
//
//  默认字号保持设计稿，跟随系统「更大字体」缩放；大数字封顶，避免挤破卡片。
//

import SwiftUI

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

private struct ScaledFont: ViewModifier {
    private static let displayThreshold: CGFloat = 28
    private static let displayMaxScale: CGFloat = 1.5

    private let size: CGFloat
    private let weight: Font.Weight?
    private let design: Font.Design?
    @ScaledMetric private var scaledSize: CGFloat

    init(size: CGFloat, weight: Font.Weight?, design: Font.Design?) {
        self.size = size
        self.weight = weight
        self.design = design
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: Self.textStyle(for: size))
    }

    func body(content: Content) -> some View {
        let limit = size >= Self.displayThreshold ? size * Self.displayMaxScale : .infinity
        return content.font(.system(size: min(scaledSize, limit), weight: weight, design: design))
    }

    private static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12: .caption2
        case ..<13: .caption
        case ..<14: .footnote
        case ..<16: .subheadline
        case ..<17: .callout
        case ..<20: .body
        case ..<22: .title3
        case ..<28: .title2
        case ..<34: .title
        default: .largeTitle
        }
    }
}
