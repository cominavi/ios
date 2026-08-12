//
//  ProgressStepView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import AuthenticationServices
import SwifterSwift
import SwiftUI
import Toast

struct ProgressStepView: View {
    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                LucideIcon("arrow.down", size: 52)
                    .foregroundStyle(.accent)
                    .padding(.leading, 2)

                Spacer()

                Text("Step 1/3")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Group {
                    Text("Downloading\ncatalog")
                        .font(.largeTitle)
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                        +
                        Text("...")
                        .font(.largeTitle)
                        .foregroundColor(.primary)
                        .bold()
                }
                .font(.title)
                .foregroundStyle(.accent)

                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
            
        }
        .padding()
        .flexibleFrame(.horizontal, alignment: .topLeading)
    }
}

#Preview {
    ProgressStepView()
        .environment(\.locale, .init(identifier: "ja"))
}
