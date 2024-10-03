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
                Image(systemName: "arrow.down")
                    .resizable()
                    .foregroundStyle(.accent)
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .padding(.leading, 2)

                Spacer()

                Text("Step 1/3")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Group {
                    Text("データベースを\nダウンロード中")
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

