//
//  SteppedProgressView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/4/24.
//

import SwiftUI

struct SteppedProgressView: View {
    var completed: Int
    var total: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< total, id: \.self) { index in
                Rectangle()
                    .frame(height: 6)
                    .foregroundStyle(index < completed ? .accent : .secondary)
            }
        }
        .clipShape(Capsule())
    }
}

struct SteppedProgressView_Previews: PreviewProvider {
    struct PreviewConfig: Hashable {
        var completed: Int
        var total: Int
    }

    static let configurations: [PreviewConfig] = [
        PreviewConfig(completed: 0, total: 4),
        PreviewConfig(completed: 1, total: 4),
        PreviewConfig(completed: 2, total: 4),
        PreviewConfig(completed: 3, total: 4),
        PreviewConfig(completed: 4, total: 4),
        PreviewConfig(completed: 1, total: 1),
        PreviewConfig(completed: 1, total: 2),
        PreviewConfig(completed: 2, total: 5)
    ]

    static var previews: some View {
        VStack(spacing: 16) {
            ForEach(configurations, id: \.self) { config in
                SteppedProgressView(completed: config.completed, total: config.total)
            }
        }
        .padding()
        .frame(width: 180)
        .previewLayout(.sizeThatFits)
    }
}
