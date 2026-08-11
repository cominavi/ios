import SwiftUI
import UIKit

struct ProfileEditorScreen: View {
    let profileStore: CominaviProfileStore

    @State private var displayName: String
    @State private var isShowingAvatarPicker = false
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
                        AuthenticatedProfileAvatar(
                            url: profileStore.profile?.avatarURL,
                            size: 104,
                            revision: profileStore.profile?.revision
                        )
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
                .disabled(profileStore.isSaving)
                .accessibilityLabel("アバターを変更")
                .accessibilityHint("写真を選択して正方形に切り抜きます")
                .accessibilityIdentifier("profile-change-avatar")

                if profileStore.profile?.avatarURL != nil {
                    Button("アバターを削除", role: .destructive, action: removeAvatar)
                        .disabled(profileStore.isSaving)
                        .accessibilityIdentifier("profile-remove-avatar")
                }
            }

            Section("プロフィール") {
                TextField("表示名", text: $displayName)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit(saveDisplayName)
                    .accessibilityIdentifier("profile-display-name")

                Button("表示名を保存", action: saveDisplayName)
                    .disabled(!canSaveDisplayName)
                    .accessibilityIdentifier("profile-save-display-name")
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
        .sheet(isPresented: $isShowingAvatarPicker) {
            SquareAvatarImagePicker { image in
                saveAvatar(image)
            }
        }
        .onChange(of: profileStore.profile?.displayName) { _, value in
            guard let value else { return }
            displayName = value
        }
    }

    private var canSaveDisplayName: Bool {
        guard let profile = profileStore.profile else { return false }
        return !profileStore.isSaving
            && displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                != profile.displayName
    }

    private func saveDisplayName() {
        Task {
            do {
                try await profileStore.saveDisplayName(displayName)
                issueMessage = nil
            } catch {
                issueMessage = error.localizedDescription
            }
        }
    }

    private func saveAvatar(_ image: UIImage) {
        Task {
            do {
                guard let jpeg = AvatarImageProcessor.squareJPEGData(from: image)
                else { throw CominaviServiceError.invalidResponse }
                try await profileStore.saveAvatar(jpeg, contentType: "image/jpeg")
                issueMessage = nil
            } catch {
                issueMessage = error.localizedDescription
            }
        }
    }

    private func removeAvatar() {
        Task {
            do {
                try await profileStore.removeAvatar()
                issueMessage = nil
            } catch {
                issueMessage = error.localizedDescription
            }
        }
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
