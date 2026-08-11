import SwiftUI
import UIKit

struct FollowingImportView: View {
    let dataSource: CirclemsDataSource
    @State private var model: FollowingImportModel

    init(dataSource: CirclemsDataSource) {
        self.dataSource = dataSource
        _model = State(initialValue: FollowingImportModel(dataSource: dataSource))
    }

    var body: some View {
        List {
            Section("X account") {
                HStack(spacing: 8) {
                    Text(verbatim: "@")
                        .foregroundStyle(.secondary)
                    TextField("username", text: $model.twitterUserName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .accessibilityIdentifier("following-import-username")
                }

                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Button {
                        Task { await model.importNow() }
                    } label: {
                        HStack {
                            Label("Import followed circles", systemImage: "arrow.down.circle")
                            Spacer()
                            if model.activity == .importing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!model.canImport)
                    .accessibilityIdentifier("following-import-start")
                }

                if let nextAllowedAt = model.nextAllowedAt {
                    LabeledContent("Next import") {
                        Text(nextAllowedAt, style: .relative)
                            .monospacedDigit()
                    }
                }

                Text(
                    "ComiNavi sends your Circle.ms session only to cominavi.net for verification. X accounts are matched to circles on this device. Imports are limited to once every six hours."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !model.importedCircles.isEmpty {
                Section("Favorite imported circles") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(BookmarkColor.selectableColors) { color in
                                Button {
                                    model.selectedColor = color
                                } label: {
                                    Circle()
                                        .fill(color.swiftUIColor)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            if model.selectedColor == color {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.bold())
                                                    .foregroundStyle(.white)
                                                    .shadow(radius: 1)
                                            }
                                        }
                                        .overlay {
                                            Circle().stroke(.primary.opacity(0.16), lineWidth: 0.5)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(color.displayName)
                                .accessibilityAddTraits(
                                    model.selectedColor == color ? .isSelected : []
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)

                    Button {
                        Task { await model.favoriteAll() }
                    } label: {
                        HStack {
                            Label("Favorite all imported circles", systemImage: "star.fill")
                            Spacer()
                            if model.activity == .favoriting {
                                ProgressView()
                            }
                        }
                        .foregroundStyle(model.selectedColor.swiftUIColor)
                    }
                    .disabled(model.activity != .idle)
                    .accessibilityIdentifier("following-import-favorite-all")
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } else if let successMessage = model.successMessage {
                Section {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                if model.importedCircles.isEmpty {
                    ContentUnavailableView(
                        "No imported circles",
                        systemImage: "person.2.slash",
                        description: Text(
                            "Import an X account to find circles it follows in this catalog."
                        )
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(model.importedCircles) { importedCircle in
                        HStack(alignment: .top, spacing: 10) {
                            NavigationLink {
                                CircleDetailView(
                                    circles: importedCircle.circles,
                                    dataSource: dataSource
                                )
                            } label: {
                                FollowingImportedCircleRow(
                                    importedCircle: importedCircle,
                                    dataSource: dataSource,
                                    favoriteColor: model.favoriteColor(for: importedCircle)
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task { await model.favorite(importedCircle) }
                            } label: {
                                Image(systemName: model.favoriteColor(for: importedCircle) == nil
                                    ? "star"
                                    : "star.fill")
                                    .font(.title3)
                                    .foregroundStyle(
                                        model.favoriteColor(for: importedCircle)?.swiftUIColor
                                            ?? model.selectedColor.swiftUIColor
                                    )
                                    .frame(width: 36, height: 44)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.activity != .idle)
                            .accessibilityLabel("Favorite this circle")
                        }
                    }
                }
            } header: {
                Text("Imported circles (\(model.importedPublicCircleCount))")
            } footer: {
                if let importState = model.importState {
                    Text(
                        "Last successful import: \(importState.importedAt.formatted(date: .abbreviated, time: .shortened)). Existing circles stay in this list when later imports add new matches."
                    )
                }
            }
        }
        .navigationTitle("X followed circles")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}

private struct FollowingImportedCircleRow: View {
    let importedCircle: FollowingImportedCircle
    let dataSource: CirclemsDataSource
    let favoriteColor: BookmarkColor?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FollowingImportedCircleArtwork(
                circle: importedCircle.circle,
                dataSource: dataSource,
                favoriteColor: favoriteColor,
                isCombinedAB: importedCircle.isCombinedAB
            )
            .frame(width: 66)

            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let placement = placementLabel {
                    Text(placement)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                ForEach(importedCircle.sources.prefix(2), id: \.twitterUserID) { source in
                    HStack(spacing: 6) {
                        AsyncImage(url: source.profilePictureURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color(uiColor: .secondarySystemFill))
                        }
                        .frame(width: 22, height: 22)
                        .clipShape(.circle)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(source.twitterDisplayName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("@\(source.twitterUserName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
    }

    private var placementLabel: String? {
        guard let blockID = importedCircle.circle.blockId,
              let block = dataSource.comiket.blocks.first(where: {
                  $0.externalBlockId == blockID
              }),
              let spaceNumber = importedCircle.circle.spaceNo
        else { return nil }
        let side = importedCircle.isCombinedAB
            ? "a+b"
            : (importedCircle.circle.spaceNoSub == 1 ? "b" : "a")
        let day = String(localized: "Day \(importedCircle.circle.day ?? 0)")
        return "\(day) · \(block.name)\(String(format: "%02d", spaceNumber))\(side)"
    }

    private var displayName: String {
        guard let name = importedCircle.circle.circleName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return String(localized: "Unnamed circle") }
        return name
    }
}

private struct FollowingImportedCircleArtwork: View {
    let circle: CirclemsDataSchema.ComiketCircleWC
    let dataSource: CirclemsDataSource
    let favoriteColor: BookmarkColor?
    let isCombinedAB: Bool

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .aspectRatio(211 / 300, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
        .overlay { CircleFavoriteMark(color: favoriteColor) }
        .overlay(alignment: .bottomTrailing) {
            if isCombinedAB {
                Text("A+B")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72), in: .capsule)
                    .padding(4)
            }
        }
        .task(id: circle.id) {
            guard let data = await dataSource.getCircleImage(circleId: circle.id),
                  !Task.isCancelled
            else { return }
            image = UIImage(data: data)
        }
        .accessibilityHidden(true)
    }
}
