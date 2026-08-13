import SwiftUI
import UIKit

struct ProfileEditorScreen: View {
    private enum AvatarChange {
        case unchanged
        case selected(UIImage)
        case removed
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appHapticFeedback) private var hapticFeedback
    let profileStore: CominaviProfileStore

    @State private var displayName: String
    @State private var isShowingAvatarPicker = false
    @State private var avatarChange = AvatarChange.unchanged
    @State private var isSavingChanges = false
    @State private var issueMessage: String?

    init(profileStore: CominaviProfileStore) {
        self.profileStore = profileStore
        _displayName = State(initialValue: profileStore.profile?.displayName ?? "")
    }

    var body: some View {
        Form {
            Section("プロフィール画像") {
                Button {
                    isShowingAvatarPicker = true
                } label: {
                    VStack(spacing: 10) {
                        editorAvatar
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(7)
                                    .background(Color.accentColor, in: .circle)
                            }

                        Text("アバターを変更")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(isSavingChanges || profileStore.isSaving)
                .accessibilityLabel("アバターを変更")
                .accessibilityHint("写真を選択して正方形に切り抜きます")
                .accessibilityIdentifier("profile-change-avatar")

                if canRemoveAvatar {
                    Button("アバターを削除", role: .destructive, action: stageAvatarRemoval)
                        .disabled(isSavingChanges)
                        .accessibilityIdentifier("profile-remove-avatar")
                }
            }

            Section("プロフィール") {
                TextField("表示名", text: $displayName)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit {
                        guard canSaveChanges else { return }
                        saveChanges()
                    }
                    .disabled(isSavingChanges)
                    .accessibilityIdentifier("profile-display-name")
            }

            if let issueMessage {
                Section {
                    Text(issueMessage)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("プロフィールを編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル", action: dismiss.callAsFunction)
                    .disabled(isSavingChanges)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: saveChanges)
                    .disabled(!canSaveChanges)
                    .accessibilityIdentifier("profile-save")
            }
        }
        .sheet(isPresented: $isShowingAvatarPicker) {
            SquareAvatarImagePicker { image in
                avatarChange = .selected(image)
            }
        }
        .interactiveDismissDisabled(isSavingChanges)
    }

    @ViewBuilder
    private var editorAvatar: some View {
        switch avatarChange {
        case .unchanged:
            AuthenticatedProfileAvatar(
                url: profileStore.profile?.avatarURL,
                size: 104,
                revision: profileStore.profile?.revision
            )
        case .selected(let image):
            Image(uiImage: image)
                .resizable()
                .renderingMode(.original)
                .scaledToFill()
                .frame(width: 104, height: 104)
                .clipShape(.circle)
                .accessibilityLabel("プロフィール画像")
        case .removed:
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: 104, height: 104)
                .accessibilityLabel("プロフィール画像なし")
        }
    }

    private var hasDisplayNameChange: Bool {
        guard let profile = profileStore.profile else { return false }
        return displayName.trimmingCharacters(in: .whitespacesAndNewlines) != profile.displayName
    }

    private var hasAvatarChange: Bool {
        if case .unchanged = avatarChange {
            return false
        }
        return true
    }

    private var canSaveChanges: Bool {
        return !isSavingChanges
            && !profileStore.isSaving
            && (hasDisplayNameChange || hasAvatarChange)
    }

    private var canRemoveAvatar: Bool {
        switch avatarChange {
        case .selected:
            true
        case .unchanged:
            profileStore.profile?.avatarURL != nil
        case .removed:
            false
        }
    }

    private func saveChanges() {
        guard canSaveChanges else { return }
        let shouldSaveDisplayName = hasDisplayNameChange
        let displayName = displayName
        let avatarChange = avatarChange
        let avatarAction = switch avatarChange {
        case .unchanged: "unchanged"
        case .selected: "upload"
        case .removed: "remove"
        }
        AppTrack.userIntent(
            .profileUpdated,
            data: [
                "display_name_changed": shouldSaveDisplayName,
                "avatar_action": avatarAction,
            ]
        )
        isSavingChanges = true
        Task {
            defer { isSavingChanges = false }
            do {
                if shouldSaveDisplayName {
                    try await profileStore.saveDisplayName(displayName)
                }

                switch avatarChange {
                case .unchanged:
                    break
                case .selected(let image):
                    guard let jpeg = AvatarImageProcessor.squareJPEGData(from: image)
                    else { throw CominaviServiceError.invalidResponse }
                    try await profileStore.saveAvatar(jpeg, contentType: "image/jpeg")
                case .removed:
                    try await profileStore.removeAvatar()
                }

                issueMessage = nil
                hapticFeedback?.play(.completion)
                dismiss()
            } catch {
                issueMessage = error.localizedDescription
                hapticFeedback?.play(.error)
            }
        }
    }

    private func stageAvatarRemoval() {
        avatarChange = profileStore.profile?.avatarURL == nil ? .unchanged : .removed
    }
}

private struct SquareAvatarImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate,
        UIImagePickerControllerDelegate
    {
        private let onSelect: (UIImage) -> Void
        private let dismiss: DismissAction

        init(onSelect: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onSelect = onSelect
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                onSelect(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

enum AvatarImageProcessor {
    static func squareJPEGData(
        from image: UIImage,
        maxPixelSize: CGFloat = 1_024
    ) -> Data? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }

        let outputSide = min(side, maxPixelSize)
        let scale = outputSide / side
        let drawSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let drawOrigin = CGPoint(
            x: (outputSide - drawSize.width) / 2,
            y: (outputSide - drawSize.height) / 2
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: outputSide, height: outputSide),
            format: format
        )
        let squareImage = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
        return squareImage.jpegData(compressionQuality: 0.88)
    }
}

#Preview {
    NavigationStack {
        ProfileEditorScreen(profileStore: AppData.profileStore)
    }
}
