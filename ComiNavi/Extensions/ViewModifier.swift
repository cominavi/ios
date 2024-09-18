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

private struct OnFirstAppear: ViewModifier {
    let perform: () -> Void
    let `else`: () -> Void

    @State private var firstTime = true

    func body(content: Content) -> some View {
        content.onAppear {
            if firstTime {
                firstTime = false
                perform()
            } else {
                `else`()
            }
        }
    }
}

private struct OnNotFirstAppear: ViewModifier {
    let perform: () -> Void

    @State private var firstTime = true

    func body(content: Content) -> some View {
        content.onAppear {
            if firstTime {
                firstTime = false
            } else {
                perform()
            }
        }
    }
}

extension View {
    func onFirstAppear(perform: @escaping () -> Void, else: @escaping () -> Void = {}) -> some View {
        modifier(OnFirstAppear(perform: perform, else: `else`))
    }

    func onNotFirstAppear(perform: @escaping () -> Void) -> some View {
        modifier(OnNotFirstAppear(perform: perform))
    }
}
