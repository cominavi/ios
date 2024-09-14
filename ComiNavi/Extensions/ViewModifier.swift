//
//  ViewModifier.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import Foundation
import SwiftUI

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ conditional: Bool, content: (Self) -> Content) -> some View {
        if conditional {
            content(self)
        } else {
            self
        }
    }

    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }

    func flexibleFrame(_ flexibleAxis: Axis.Set = [.horizontal, .vertical],
                       alignment: Alignment = .center) -> some View
    {
        frame(
            maxWidth: flexibleAxis.contains(.horizontal) ? .infinity : nil,
            maxHeight: flexibleAxis.contains(.vertical) ? .infinity : nil,
            alignment: alignment
        )
    }
}
