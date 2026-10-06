import SwiftUI
import UniformTypeIdentifiers

// MARK: - Profile manager

/// Save, load, import and export rigs. A rig is one JSON file describing port
/// names and the whole patchbay, so a studio or a tour can keep one per venue
/// and hand them around.
public struct ProfileManagerView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var engine: MIDIEngine

    @State private var draftName = ""
    @State private var draftDetails = ""
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportTarget: RigProfile?

    public init(engine: MIDIEngine) {
        self.engine = engine
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                library
                    .frame(minWidth: 260, idealWidth: 300)
                savePane
                    .frame(minWidth: 300)
            }
        }
        .frame(width: 760, height: 460)
        .background(Palette.panelRaised)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                state.importProfile(from: url)
            case let .failure(error):
                state.show(toast: "Import failed: \(error.localizedDescription)")
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportTarget.map { RigDocument(profile: $0) },
            contentType: .json,
            defaultFilename: exportTarget?.name ?? "Rig"
        ) { result in
            if case let .failure(error) = result {
                state.show(toast: "Export failed: \(error.localizedDescription)")
            } else if case .success = result {
                state.show(toast: "Rig exported")
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Rigs")
                    .font(.system(size: 15, weight: .semibold))
                Text("A rig is every port name and every route, saved as one JSON file.")
                    .font(.system(size: 10))
                    .mutedText()
            }
            Spacer()
            Button("Import…") {
                isImporting = true
            }
            .controlSize(.small)
            Button("Done") {
                state.isProfileManagerPresented = false
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.store.profiles.isEmpty {
                EmptyStateView(
                    symbol: "square.stack.3d.up",
                    title: "No rigs yet",
                    message: "Save the current patch on the right to create your first rig."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.store.profiles) { profile in
                            profileRow(profile)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Palette.windowBackground)
    }

    private func profileRow(_ profile: RigProfile) -> some View {
        let isActive = state.store.activeProfileID == profile.id
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(profile.name)
                        .font(.system(size: 12, weight: .medium))
                    if isActive {
                        Text("active")
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Palette.accent.opacity(0.3)))
                    }
                }
                Text("\(profile.routes.count) routes · updated \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9))
                    .mutedText()
                if !profile.details.isEmpty {
                    Text(profile.details)
                        .font(.system(size: 9))
                        .faintText()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            Button {
                state.load(profile: profile)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .help("Load this rig")

            Button {
                exportTarget = profile
                isExporting = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Export to a file")

            Button(role: .destructive) {
                state.delete(profile: profile)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this rig")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Palette.accent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            state.load(profile: profile)
        }
    }

    // MARK: Save pane

    private var savePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save current patch")
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 10, weight: .medium))
                    .mutedText()
                TextField("Live room, Studio B, Support slot…", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.system(size: 10, weight: .medium))
                    .mutedText()
                TextEditor(text: $draftDetails)
                    .font(.system(size: 11))
                    .frame(height: 70)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Palette.sunkenFill))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.stroke.opacity(0.5)))
            }

            Panel(title: "What gets saved") {
                VStack(alignment: .leading, spacing: 3) {
                    Label("\(engine.routes.count) routes with their filters and transforms", systemImage: "arrow.triangle.branch")
                    Label("\(engine.portConfigs.count) custom port names", systemImage: "textformat")
                    Label("no audio settings — this device is MIDI only", systemImage: "info.circle")
                }
                .font(.system(size: 10))
                .mutedText()
            }

            HStack(spacing: 8) {
                Button {
                    let name = draftName.isEmpty
                        ? (state.store.activeProfile?.name ?? "Untitled rig")
                        : draftName
                    state.saveCurrentAsProfile(named: name, details: draftDetails)
                    draftName = ""
                    draftDetails = ""
                } label: {
                    Label("Save rig", systemImage: "square.and.arrow.down")
                }

                if let active = state.store.activeProfile {
                    Button {
                        state.saveCurrentAsProfile(named: active.name, details: draftDetails)
                    } label: {
                        Label("Update “\(active.name)”", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Spacer()
            }
            .controlSize(.small)

            Divider()

            Text("Rigs live in \(state.store.supportDirectory.path)")
                .font(.system(size: 9))
                .faintText()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(14)
    }
}

// MARK: - File document

/// Wraps a rig so SwiftUI's file exporter can write it.
struct RigDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var profile: RigProfile

    init(profile: RigProfile) {
        self.profile = profile
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        profile = try RigCoding.makeDecoder().decode(RigProfile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: try RigCoding.makeEncoder().encode(profile))
    }
}
