import BerryGraph
import BerryStore
import Foundation
import Observation
import SwiftUI

/// What the "Schemas to Index" sheet lists and saves for one saved
/// connection: the schemas the stored graph holds, each with its number of
/// tables and views, and the ones the harvest is limited to. Kept apart from
/// the view so the rules are testable without SwiftUI.
@MainActor
@Observable
final class SchemaScopeModel: Identifiable {
    struct Schema: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// The profile the scope belongs to.
    let id: UUID
    private(set) var schemas: [Schema] = []
    /// Whether the stored graph holds any object of the profile yet.
    private(set) var hasIndexedObjects = false
    /// The last pass found more tables than a whole-catalog pass handles well.
    private(set) var suggestsNarrowing = false
    private(set) var isLoaded = false
    private(set) var saveError: String?
    var allSchemas = true
    var selected: Set<String> = []

    /// An empty selection would index nothing, so it is never saved.
    var canSave: Bool { isLoaded && (allSchemas || !selected.isEmpty) }

    @ObservationIgnored private let store: BerryStore
    @ObservationIgnored private let stopPasses: () async -> Void
    @ObservationIgnored private let didSave: () async -> Void
    @ObservationIgnored private let now: () -> Date

    /// `stopPasses` cancels the profile's harvest passes before a narrower
    /// scope deletes rows; `didSave` runs once the scope is stored.
    init(
        profileID: UUID, store: BerryStore,
        stopPasses: @escaping () async -> Void, didSave: @escaping () async -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.id = profileID
        self.store = store
        self.stopPasses = stopPasses
        self.didSave = didSave
        self.now = now
    }

    /// Reads the schema counts and the stored scope off the main actor. A
    /// selected schema that holds nothing yet is listed with a count of zero,
    /// so it can still be unselected.
    func load() async {
        let profileID = id
        let store = store
        let (counts, state) = await Task.detached(priority: .userInitiated) {
            let reader = GraphReader(store: store)
            return ((try? reader.schemaCounts(profileID: profileID)) ?? [], try? reader.state(profileID: profileID))
        }.value
        hasIndexedObjects = !counts.isEmpty
        suggestsNarrowing = state?.hint == "selectSchemas"
        var countByName: [String: Int] = [:]
        for entry in counts {
            if let name = entry.database { countByName[name] = entry.count }
        }
        for name in state?.selectedSchemas ?? [] where countByName[name] == nil { countByName[name] = 0 }
        schemas = countByName.keys.sorted().map { Schema(name: $0, count: countByName[$0] ?? 0) }
        allSchemas = state?.selectedSchemas == nil || schemas.isEmpty
        selected = Set(state?.selectedSchemas ?? schemas.map(\.name))
        isLoaded = true
    }

    /// Stores the scope and returns whether it did, after stopping the
    /// profile's passes. A selection of schemas also deletes every stored
    /// object outside it, with its relations, statistics and name vector, in
    /// the same transaction: the next pass lists only the selection and would
    /// otherwise record those objects as dropped from the database. The
    /// delete moves the change time even when nothing lies outside the
    /// selection.
    func save() async -> Bool {
        guard canSave else { return false }
        let selection: [String]? = allSchemas || schemas.isEmpty ? nil : selected.sorted()
        await stopPasses()
        let store = store
        let profileID = id
        let changedAt = now()
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.saveSchemaScope(profileID: profileID, selectedSchemas: selection, now: changedAt)
            }.value
        } catch {
            saveError = error.localizedDescription
            return false
        }
        saveError = nil
        await didSave()
        return true
    }
}

/// The sheet behind a connection's "Schemas to Index…" menu item.
struct SchemaScopeView: View {
    @Bindable var model: SchemaScopeModel
    let connectionName: String
    let onClose: () -> Void

    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BerryTheme.Space.xs) {
                Text(L("Schemas to Index")).font(.headline)
                Text(connectionName).font(.callout).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420, height: 460)
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        if !model.isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.schemas.isEmpty {
            VStack(alignment: .leading, spacing: BerryTheme.Space.sm) {
                Toggle(L("All schemas"), isOn: .constant(true))
                    .toggleStyle(.checkbox)
                    .disabled(true)
                Text(model.hasIndexedObjects
                     ? L("This connection has no schemas to choose from.")
                     : L("Nothing is indexed for this connection yet. Every schema is indexed when it connects."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(L("All schemas"), isOn: $model.allSchemas)
                    .toggleStyle(.checkbox)
                    .padding()
                List(model.schemas) { schema in
                    Toggle(isOn: binding(for: schema.name)) {
                        HStack {
                            Text(schema.name)
                            Spacer()
                            Text(schema.count, format: .number)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .disabled(model.allSchemas)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: BerryTheme.Space.sm) {
            if model.suggestsNarrowing {
                Label(L("More than 20,000 tables — pick the schemas to index"), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let error = model.saveError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    isSaving = true
                    Task {
                        let saved = await model.save()
                        isSaving = false
                        if saved { onClose() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave || isSaving)
            }
        }
        .padding()
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { model.selected.contains(name) },
            set: { isOn in
                if isOn { model.selected.insert(name) } else { model.selected.remove(name) }
            }
        )
    }
}
