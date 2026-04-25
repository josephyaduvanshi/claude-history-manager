import SwiftUI

/// Popover invoked from the session-row "Tag…" context action or the
/// preview pane's overflow menu. Lets the user toggle which tags are
/// applied to `session` and create a new tag inline with a color-hue
/// swatch chooser.
///
/// Selections are held in local state until the user dismisses via the
/// checkmark button (or the popover closes), at which point `onSave`
/// fires with the new tag id set.
struct TagPicker: View {
    let session: SessionMetadata
    let appliedTagIDs: Set<Int64>
    let allTags: [Tag]
    let onSave: ([Int64]) -> Void
    let onClose: () -> Void
    let onCreateTag: @MainActor (String, Int) async -> Tag?
    /// Optional rename. Wired via UserMetadataActions when present, no-op otherwise.
    var onRenameTag: (@MainActor (Int64, String) async -> Void)? = nil
    /// Optional delete. Cascades through `session_tags` (handled in repo).
    var onDeleteTag: (@MainActor (Int64) async -> Void)? = nil

    @State private var filter: String = ""
    @State private var selected: Set<Int64> = []
    @State private var creating: Bool = false
    @State private var newName: String = ""
    @State private var newHue: Int = 30
    /// Edit mode shows rename / delete affordances next to each row.
    @State private var editMode: Bool = false
    @State private var renamingTagID: Int64? = nil
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().overlay(Theme.Color.rule)

            searchRow
            Divider().overlay(Theme.Color.rule)

            list

            Divider().overlay(Theme.Color.rule)
            footer
        }
        .frame(width: 300)
        .background(Theme.Color.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.Color.ruleStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            selected = appliedTagIDs
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Tag session")
                .font(Theme.Font.titleSmall)
                .foregroundStyle(Theme.Color.text)
            Spacer()
            if onRenameTag != nil || onDeleteTag != nil {
                Button {
                    editMode.toggle()
                    renamingTagID = nil
                } label: {
                    Text(editMode ? "Done" : "Edit")
                        .font(Theme.Font.mono(size: 11, wght: 500))
                        .foregroundStyle(Theme.Color.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Text("⌕")
                .font(Theme.Font.mono(size: 11, wght: 500))
                .foregroundStyle(Theme.Color.textFaint)
            TextField("", text: $filter, prompt:
                Text("Filter tags…")
                    .foregroundStyle(Theme.Color.textFaint)
            )
            .textFieldStyle(.plain)
            .font(Theme.Font.bodyBase)
            .foregroundStyle(Theme.Color.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredTags) { tag in
                    tagRow(tag)
                }
                if filteredTags.isEmpty && !creating {
                    Text("— no matches —")
                        .font(Theme.Font.mono(size: 11, wght: 400))
                        .foregroundStyle(Theme.Color.textDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
        .frame(maxHeight: 220)
    }

    @ViewBuilder
    private func tagRow(_ tag: Tag) -> some View {
        if editMode {
            HStack(spacing: 10) {
                Circle().fill(tag.swiftUIColor).frame(width: 7, height: 7)
                if renamingTagID == tag.id {
                    TextField("", text: $renameDraft, prompt:
                        Text(tag.name).foregroundStyle(Theme.Color.textFaint)
                    )
                    .textFieldStyle(.plain)
                    .font(Theme.Font.bodyBase)
                    .foregroundStyle(Theme.Color.text)
                    .onSubmit { commitRename(for: tag) }
                    Button {
                        commitRename(for: tag)
                    } label: {
                        Text("Save")
                            .font(Theme.Font.mono(size: 10, wght: 500))
                            .foregroundStyle(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                    Button {
                        renamingTagID = nil
                        renameDraft = ""
                    } label: {
                        Text("Cancel")
                            .font(Theme.Font.mono(size: 10, wght: 500))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(tag.name)
                        .font(Theme.Font.bodyBase)
                        .foregroundStyle(Theme.Color.text)
                    Spacer()
                    if onRenameTag != nil {
                        Button {
                            renamingTagID = tag.id
                            renameDraft = tag.name
                        } label: {
                            Text("rename")
                                .font(Theme.Font.mono(size: 10, wght: 500))
                                .foregroundStyle(Theme.Color.textDim)
                        }
                        .buttonStyle(.plain)
                    }
                    if onDeleteTag != nil {
                        Button {
                            let id = tag.id
                            Task { @MainActor in
                                await onDeleteTag?(id)
                                selected.remove(id)
                            }
                        } label: {
                            Text("delete")
                                .font(Theme.Font.mono(size: 10, wght: 500))
                                .foregroundStyle(Color.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        } else {
            Button {
                toggle(tag.id)
            } label: {
                HStack(spacing: 10) {
                    checkbox(checked: selected.contains(tag.id))
                    Circle().fill(tag.swiftUIColor).frame(width: 7, height: 7)
                    Text(tag.name)
                        .font(Theme.Font.bodyBase)
                        .foregroundStyle(Theme.Color.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    private func commitRename(for tag: Tag) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag.name else {
            renamingTagID = nil
            renameDraft = ""
            return
        }
        let id = tag.id
        Task { @MainActor in
            await onRenameTag?(id, trimmed)
            renamingTagID = nil
            renameDraft = ""
        }
    }

    private func checkbox(checked: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(checked ? Theme.Color.accent : Theme.Color.ruleStrong, lineWidth: 1)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(checked ? Theme.Color.accentSoft : .clear)
            )
            .overlay {
                if checked {
                    Text("✓")
                        .font(Theme.Font.mono(size: 10, wght: 500))
                        .foregroundStyle(Theme.Color.accent)
                }
            }
    }

    @ViewBuilder
    private var footer: some View {
        if creating {
            newTagForm
        } else {
            HStack {
                Button {
                    creating = true
                    newName = filter
                    filter = ""
                } label: {
                    Text("+ New tag")
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    onSave(Array(selected))
                } label: {
                    Text("Done")
                        .font(Theme.Font.btnPrimary)
                        .foregroundStyle(Theme.Color.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var newTagForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $newName, prompt:
                Text("tag name").foregroundStyle(Theme.Color.textFaint)
            )
            .textFieldStyle(.plain)
            .font(Theme.Font.bodyBase)
            .foregroundStyle(Theme.Color.text)

            HStack(spacing: 6) {
                ForEach(Tag.palette, id: \.self) { hue in
                    let c = Tag.oklchLike(hue: hue)
                    Button {
                        newHue = hue
                    } label: {
                        Circle()
                            .fill(c)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(newHue == hue ? Theme.Color.accent : .clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            HStack {
                Button("Cancel") {
                    creating = false
                    newName = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Button {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task {
                        if let tag = await onCreateTag(trimmed, newHue) {
                            selected.insert(tag.id)
                        }
                        creating = false
                        newName = ""
                    }
                } label: {
                    Text("Create")
                        .font(Theme.Font.btnPrimary)
                        .foregroundStyle(Theme.Color.onAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Data

    private var filteredTags: [Tag] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allTags }
        return allTags.filter { $0.name.lowercased().contains(q) }
    }

    private func toggle(_ id: Int64) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}
