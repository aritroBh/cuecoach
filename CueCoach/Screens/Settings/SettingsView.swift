import Geometry
import Rules
import SwiftUI
import UniformTypeIdentifiers

/// Settings (SPEC §11, design-system/cuecoach/pages/screens-a.md §1). Pushed from Home by its owner.
public struct SettingsView: View {
    @State private var model: SettingsViewModel
    @State private var importing = false
    @State private var shareURL: SAShareItem?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.saForceReduceMotion) private var forceReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReduceMotion }
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    public init(model: SettingsViewModel) { _model = State(initialValue: model) }

    private var motion: SAMotion { SAMotion(reduce: reduceMotion) }

    public var body: some View {
        ScrollView {
            Group {
                if vSize == .compact {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(spacing: AX.space.s6) { privacy; backup }
                        VStack(spacing: AX.space.s6) { rules; table; developer }
                    }
                } else {
                    VStack(spacing: AX.space.s6) { privacy; backup; rules; table; developer }
                }
            }
            .padding(.horizontal, vSize == .compact ? 24 : AX.space.s4)
            .padding(.vertical, 8)
        }
        .background(AX.page.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(AX.page, for: .navigationBar)
        .tint(AX.accentText)   // Astryx text-accent: legible as words on bars in dark mode
        // The Undo window closes as soon as the app leaves the foreground or Settings is left.
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.commitPendingDelete() } }
        .onDisappear { model.commitPendingDelete() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false,
                      onCompletion: handleImport, onCancellation: { model.importCancelled() })
        .alert("Can't import", isPresented: Binding(get: { model.importAlert != nil },
                                                    set: { if !$0 { model.importAlert = nil } })) {
            Button("OK", role: .cancel) { model.importAlert = nil }
        } message: {
            Text(model.importAlert?.message ?? "")
        }
        .sheet(item: $shareURL, onDismiss: { model.shareFinished() }) { item in
            SAShareSheet(url: item.url).presentationDetents([.medium, .large])
        }
        .animation(motion.snappy, value: model.showsThreeBallToggle)
        .animation(motion.snappy, value: model.deleteState)
        .accessibilityIdentifier("screen.settings")
    }

    // MARK: Privacy

    private var privacy: some View {
        VStack(spacing: 8) {
            AXSectionHeader("Privacy")
            SACard(padding: 0) {
                VStack(spacing: 0) {
                    Toggle(isOn: Binding(get: { model.recognitionOptIn },
                                         set: { model.recognitionOptIn = $0; Haptics.selection() })) {
                        SARowLabel(symbol: "person.crop.circle.badge.checkmark", title: "Recognize me",
                                 helper: "Stays on this phone.")
                    }
                    .padding(16)
                    .frame(minHeight: 60)
                    .accessibilityIdentifier("settings.recognition")
                    Divider().overlay(AX.border).padding(.leading, 60)
                    deleteRow
                }
            }
        }
    }

    private var deleteRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button { delete() } label: {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(AX.danger.opacity(0.15)).frame(width: 28, height: 28)
                            switch model.deleteState {
                            case .undoable, .deleted:
                                Image(systemName: "checkmark").axFont(.label, weight: .semibold).foregroundStyle(AX.legal)
                                    .transition(.opacity)
                            default:
                                Image(systemName: "trash").axFont(.label, weight: .regular).foregroundStyle(AX.danger)
                            }
                        }
                        Text(SettingsViewModel.deleteRowTitle).axFont(.body).foregroundStyle(AX.danger)
                        Spacer(minLength: 8)
                    }
                    .padding(16)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canDelete)
                .opacity(model.canDelete || model.deleteState == .undoable || model.deleteState == .deleted ? 1 : 0.4)
                .accessibilityHint("Removes face and look data from this phone.")
                .accessibilityIdentifier("settings.delete")
                if model.deleteState == .undoable {
                    // Non-modal: the rest of Settings stays usable; the window closes on its own after ~5 s.
                    Button { model.undoDelete(); Haptics.selection() } label: {
                        Text(SettingsViewModel.undoTitle).axFont(.headline).foregroundStyle(AX.legal)
                            .padding(.horizontal, 16)
                            .frame(minWidth: 64, minHeight: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Restores face and look data.")
                    .accessibilityIdentifier("settings.delete.undo")
                    .transition(.opacity)
                }
            }
            // Outside the dimmed button so the only explanation for the disabled row stays readable.
            if !model.hasRecognitionData && model.deleteState == .idle {
                Text("Nothing stored.").axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                    .padding(.leading, 60).padding(.trailing, 16).padding(.top, -12).padding(.bottom, 14)
                    .accessibilityIdentifier("settings.delete.helper")
            }
            if model.deleteState == .failed {
                Text("Couldn't delete. Try again.")
                    .axFont(.label, weight: .semibold).foregroundStyle(AX.danger)
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .accessibilityIdentifier("settings.delete.error")
            }
        }
    }

    /// One tap deletes (SPEC §2): no confirmation step; Undo stands in for it.
    private func delete() {
        model.deleteTapped()
        Haptics.notify(model.deleteState == .undoable ? .success : .error)
        Task {
            while model.deleteState == .undoable { try? await Task.sleep(for: .milliseconds(200)) }
            if model.deleteState == .deleted {
                try? await Task.sleep(for: .seconds(1.5)); model.settle()
            }
        }
    }

    // MARK: Backup

    private var backup: some View {
        VStack(spacing: 8) {
            AXSectionHeader("Backup")
            SAAdaptiveStack(spacing: 12) {
                BackupTile(symbol: "square.and.arrow.up", title: "Export",
                           busy: model.exportState == .exporting, done: false) {
                    Task {
                        if let url = await model.export() { shareURL = SAShareItem(url: url); Haptics.notify(.success) }
                        else { Haptics.notify(.error) }
                    }
                }
                .accessibilityIdentifier("settings.export")
                BackupTile(symbol: "square.and.arrow.down", title: "Import",
                           busy: model.importState == .importing, done: model.importState == .done) {
                    importing = true   // state changes only once a file comes back
                }
                .accessibilityIdentifier("settings.import")
            }
            .disabled(!model.backupEnabled)
            if model.exportState == .failed {
                Text("Export failed.").axFont(.label, weight: .semibold).foregroundStyle(AX.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { model.importCancelled(); return }
        model.importFile(at: url)
        Haptics.notify(model.importState == .done ? .success : .error)
        if model.importState == .done {
            Task { try? await Task.sleep(for: .seconds(1.5)); model.settle() }
        }
    }

    // MARK: Rules

    private var rules: some View {
        VStack(spacing: 8) {
            AXSectionHeader("Rules")
            SACard(padding: 12) {
                VStack(spacing: 8) {
                    SAAdaptiveStack(spacing: 8) {
                        ForEach(RuleSetID.allCases, id: \.self) { r in
                            RuleTile(rule: r, selected: model.ruleSet == r) {
                                model.ruleSet = r; Haptics.selection()
                            }
                        }
                    }
                    if model.showsThreeBallToggle {
                        Divider().overlay(AX.border)
                        Toggle(isOn: Binding(get: { model.threeBallRule },
                                             set: { model.threeBallRule = $0; Haptics.selection() })) {
                            SARowLabel(symbol: "3.circle", title: "Three-ball rule", helper: "Soft breaks re-rack.")
                        }
                        .padding(.horizontal, 4)
                        .frame(minHeight: 56)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("settings.threeBall")
                    }
                }
            }
        }
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 8) {
            AXSectionHeader("Table")
            SACard(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SAAdaptiveStack(spacing: 8) {
                        ForEach(TableSize.allCases, id: \.self) { size in
                            TableTile(size: size, selected: model.tableSize == size,
                                      label: model.tableAccessibilityLabel(size)) {
                                model.selectTable(size); Haptics.selection()
                            }
                        }
                    }
                    if let note = model.tableNote {
                        Label(note == .autoMeasured ? "Auto-measured" : "Manual",
                              systemImage: note == .autoMeasured ? "sensor.fill" : "hand.tap")
                            .axFont(.label, weight: .semibold)
                            .foregroundStyle(AX.inkMuted)
                            .padding(.horizontal, 4)
                            .accessibilityIdentifier("settings.tableNote")
                    }
                }
            }
        }
    }

    // MARK: Developer

    private var developer: some View {
        VStack(spacing: 8) {
            AXSectionHeader("Developer").foregroundStyle(AX.inkMuted)
            Toggle(isOn: Binding(get: { model.debugHUD }, set: { model.debugHUD = $0; Haptics.selection() })) {
                SARowLabel(symbol: "gauge.with.dots.needle.33percent", title: "Debug HUD", helper: nil, muted: true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .accessibilityIdentifier("settings.debugHUD")
        }
    }
}

// MARK: - Pieces

struct SARowLabel: View {
    let symbol: String
    let title: String
    let helper: String?
    var muted = false
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(AX.inkMuted.opacity(0.15)).frame(width: 28, height: 28)
                Image(systemName: symbol).axFont(.label, weight: .regular).foregroundStyle(AX.inkMuted)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).axFont(.body).foregroundStyle(muted ? AX.inkMuted : AX.ink)
                if let helper {
                    Text(helper).axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                }
            }
        }
    }
}

/// Horizontal row that becomes a vertical list at accessibility Dynamic Type sizes.
struct SAAdaptiveStack<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: spacing))
                                              : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
    }
}

private struct BackupTile: View {
    @ScaledMetric(relativeTo: .title) private var glyph: CGFloat = 28
    let symbol: String
    let title: String
    let busy: Bool
    let done: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if busy { ProgressView() }
                    else {
                        Image(systemName: done ? "checkmark" : symbol)
                            .font(.system(size: glyph, weight: .semibold))
                            .foregroundStyle(done ? AX.legal : AX.ink)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(minHeight: glyph + 6)
                Text(title).axFont(.headline).foregroundStyle(AX.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(AX.surface, in: RoundedRectangle(cornerRadius: AX.radius.element, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AX.radius.element))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(title + " backup")
    }
}

/// Ball glyph: black disc with "8" or a yellow-striped disc with "9".
struct SARuleBall: View {
    let number: Int
    @ScaledMetric private var size: CGFloat
    init(number: Int, size: CGFloat = 40) {
        self.number = number
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }
    var body: some View {
        ZStack {
            Circle().fill(AX.ball(number))
            if number == 9 {
                Circle().fill(AX.ballWhite).mask(
                    VStack(spacing: 0) {
                        Rectangle().frame(height: size * 0.22)
                        Spacer(minLength: 0)
                        Rectangle().frame(height: size * 0.22)
                    })
            }
            Circle().fill(AX.ballWhite).frame(width: size * 0.52)
            Text("\(number)").font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(AX.pocket)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(AX.inkMuted.opacity(0.4), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

private struct RuleTile: View {
    let rule: RuleSetID
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                SARuleBall(number: SettingsViewModel.ruleBall(rule))
                Text(SettingsViewModel.ruleShortLabel(rule))
                    .axFont(.headline).foregroundStyle(selected ? AX.ink : AX.inkMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: AX.radius.element).fill(selected ? AX.accentMuted : AX.muted))
            .overlay(RoundedRectangle(cornerRadius: AX.radius.element).strokeBorder(selected ? AX.accent : AX.border, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").axFont(.subtitle, weight: .regular).foregroundStyle(AX.accent).padding(6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SettingsViewModel.ruleLabel(rule))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.rule.\(rule.rawValue)")
    }
}

/// Felt + rail silhouette: every table 2:1, sized 7:8:9 by playing length, with 6 pocket dots.
struct SATableSilhouette: View {
    let size: TableSize
    var body: some View {
        Canvas { ctx, box in
            let rect = SettingsViewModel.silhouetteRect(size, in: box)
            let h = rect.height
            let rail = max(3, h * 0.12)
            ctx.fill(Path(roundedRect: rect, cornerRadius: rail), with: .color(AX.rail))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: rail), with: .color(AX.railHighlight), lineWidth: 1)
            let felt = rect.insetBy(dx: rail, dy: rail)
            ctx.fill(Path(felt), with: .color(AX.felt))
            let r = max(2, rail * 0.45)
            for x in [felt.minX, felt.midX, felt.maxX] {
                for y in [felt.minY, felt.maxY] {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(AX.pocket))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TableTile: View {
    let size: TableSize
    let selected: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                SATableSilhouette(size: size).frame(height: 44)
                Text("\(SettingsViewModel.feet(size)) ft")
                    .axFont(.headline).monospacedDigit()
                    .foregroundStyle(selected ? AX.ink : AX.inkMuted)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: AX.radius.element).fill(selected ? AX.accentMuted : AX.muted))
            .overlay(RoundedRectangle(cornerRadius: AX.radius.element).strokeBorder(selected ? AX.accent : AX.border, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").axFont(.subtitle, weight: .regular).foregroundStyle(AX.accent).padding(6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.table.\(size.rawValue)")
    }
}

struct SAShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct SAShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview("Settings") {
    NavigationStack {
        SettingsView(model: SettingsViewModel(store: InMemorySettingsStore(hasRecognitionData: true)))
    }
}
