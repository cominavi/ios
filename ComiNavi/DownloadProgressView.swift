//
//  DownloadProgressView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import SwiftUI

class DownloadProgressViewRateEstimator: ObservableObject {
    @Published
    var estimatedRate: Double = 0
    
    var recentSamples: [Double] = []
    let samplesCount = 10
    let updateInterval = 1.0
    var timer: Timer?
    
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.estimatedRate = self?.recentSamples.reduce(0, +) ?? 0 / Double(self?.recentSamples.count ?? 1)
        }
    }
    
    func addSample(_ absoluteValue: Int64) {
        let sample = Double(absoluteValue)
        
        recentSamples.append(sample)
        
        if recentSamples.count > samplesCount {
            recentSamples.removeFirst()
        }
        
        estimatedRate = recentSamples.reduce(0, +) / Double(recentSamples.count)
        
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
                self?.estimatedRate = self?.recentSamples.reduce(0, +) ?? 0 / Double(self?.recentSamples.count ?? 1)
            }
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}

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
        .animation(.none)
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
