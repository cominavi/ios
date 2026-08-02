//
//  DownloadProgressView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import SwiftUI

struct DownloadProgressView: View {
    var progresses: Readiness.Progresses

    var body: some View {
        VStack {
            ProgressView(value: progresses.fractionCompleted, total: 1.0)
                .tint(.accentColor)
            
            HStack {
                Text("\(progresses.completedBytes.byteSizeString) / \(progresses.totalBytes.byteSizeString)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .monospacedDigit()
                
                Spacer()
                
                Text(progresses.fractionCompleted.percentString(decimalPlaces: 2))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }
}

#Preview {
    VStack {
        DownloadProgressView(progresses: [.init(type: .main, totalBytes: 10000, completedBytes: 1000)])

        DownloadProgressView(progresses: [
            .init(type: .main, totalBytes: 10000, completedBytes: 1000),
            .init(type: .main, totalBytes: 40000, completedBytes: 2000)
        ])
    }
    .padding(.horizontal, 32)
}
