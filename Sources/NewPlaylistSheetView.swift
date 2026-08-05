import SwiftUI

/// 新建 / 重命名歌单表单（sheet 展示，避免 alert 内 TextField 在部分 iOS 上不可编辑的问题）。
/// 传入 `renameID` 时进入重命名模式。
struct NewPlaylistSheetView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @Environment(\.dismiss) private var dismiss

    var renameID: String?
    var initialName: String = ""

    var onCreate: (LXPlaylist) -> Void = { _ in }

    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var isRename: Bool { renameID != nil }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("歌单名称", text: $name)
                        .font(.system(size: 16))
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { create() }
                } footer: {
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.system(size: 13))
                    }
                }
                Section {
                    Button(action: create) {
                        HStack(spacing: 8) {
                            Text(isRename ? "保存" : "创建歌单")
                                .frame(maxWidth: .infinity, alignment: .center)
                            if isCreating {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(trimmedName.isEmpty || isCreating)
                }
            }
            .navigationTitle(isRename ? "重命名歌单" : "新建歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            name = initialName
            nameFocused = true
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func create() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        if let rid = renameID {
            isCreating = true
            Task {
                try? await playlistStore.renamePlaylist(id: rid, newName: name)
                isCreating = false
                dismiss()
            }
            return
        }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                try await playlistStore.createPlaylist(name: name)
                if let created = playlistStore.playlists.first(where: { $0.name == name }) {
                    onCreate(created)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
