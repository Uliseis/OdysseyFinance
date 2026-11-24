import SwiftUI
import SwiftData
import LocalAuthentication
import CoreModel
import CoreLogic

// The Settings tab — single home for every secondary surface (was two toolbar "More"
// menus). All navigationDestinations are registered here so DEBUG hooks can deep-push.
struct SettingsView: View {
    @State private var path = NavigationPath()
    @AppStorage(SecuritySettings.requireUnlockKey) private var requireUnlock = true
    @AppStorage(CycleSettings.startDayKey) private var cycleStartDay = 1
    @AppStorage(CycleSettings.startsEarlyOnWeekendsKey) private var startsEarlyOnWeekends = true
    @AppStorage(CycleSettings.oneOffStartsKey) private var oneOffStartsStored = ""
    @State private var movingAStart = false
    #if DEBUG
    @Query(sort: [SortDescriptor(\SharedExpenseGroup.createdAt, order: .reverse)])
    private var debugGroups: [SharedExpenseGroup]
    @Query(sort: [SortDescriptor(\Connection.institutionName)])
    private var debugConnections: [Connection]
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    SettingsBrandHeader(version: Self.versionString)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section {
                    SettingsLinkRow(title: "Connections", systemImage: "link", destination: .connections)
                    SettingsLinkRow(title: "Trading 212", systemImage: "chart.line.uptrend.xyaxis", destination: .trading212)
                    SettingsLinkRow(title: "Fund Prices (EODHD)", systemImage: "chart.bar.doc.horizontal", destination: .fundPrices)
                }
                Section("Money") {
                    SettingsLinkRow(title: "Transfers", systemImage: "arrow.left.arrow.right", destination: .transfers)
                    SettingsLinkRow(title: "Matches", systemImage: "plusminus.circle", destination: .sharedExpenses)
                    SettingsLinkRow(title: "Budgets", systemImage: "chart.pie", destination: .budgets)
                    SettingsLinkRow(title: "Automations", systemImage: "bolt.badge.clock", destination: .automations)
                    SettingsLinkRow(title: "Claude", systemImage: "sparkles", destination: .claude)
                }
                Section {
                    Picker(selection: $cycleStartDay) {
                        ForEach(1...CoreLogic.Dashboard.maxCycleStartDay, id: \.self) { day in
                            Text(day == 1 ? "1st (calendar month)" : Self.ordinal(day)).tag(day)
                        }
                    } label: {
                        HStack(spacing: Theme.Space.m) {
                            IconBadge(systemName: "calendar")
                            Text("Month Starts On")
                        }
                    }
                    .pickerStyle(.menu)
                    if cycleStartDay != 1 {
                        Toggle("Start Friday Before a Weekend", isOn: $startsEarlyOnWeekends)
                    }
                    ForEach(oneOffStarts, id: \.self) { start in
                        LabeledContent("Starts \(Self.day.string(from: start))",
                                       value: "not \(Self.shortDay.string(from: cycle.usualStart(movedTo: start)))")
                    }
                    .onDelete { offsets in
                        var starts = oneOffStarts
                        starts.remove(atOffsets: offsets)
                        oneOffStartsStored = CycleSettings.storing(starts)
                    }
                    Button("Move One Month's Start…") { movingAStart = true }
                } footer: {
                    Text(cycleFooter)
                }
                Section("Manage") {
                    SettingsLinkRow(title: "Categories", systemImage: "tag", destination: .categories)
                    SettingsLinkRow(title: "Rules", systemImage: "wand.and.stars", destination: .rules)
                    SettingsLinkRow(title: "Transfer Routes", systemImage: "arrow.triangle.branch", destination: .transferRoutes)
                    SettingsLinkRow(title: "Spaces", systemImage: "rectangle.stack", destination: .spaces)
                    SettingsLinkRow(title: "Groups", systemImage: "square.stack.3d.up", destination: .groups)
                }
                Section {
                    Toggle("Require Face ID", isOn: $requireUnlock)
                        .onChange(of: requireUnlock) { wasOn, isOn in
                            if wasOn && !isOn { confirmDisable() }
                        }
                    LabeledContent("iCloud Sync", value: CloudKitGate.isAvailable ? "On" : "Unavailable")
                } header: {
                    Text("App")
                } footer: {
                    Text(CloudKitGate.isAvailable
                         ? "Locks when the app goes to the background. Turning the lock off requires Face ID."
                         : "Locks when the app goes to the background. Turning the lock off requires Face ID. Sync needs an iCloud-signed-in, entitled build.")
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .connections: ConnectionsListView()
                case .automations: AutomationsView()
                case .transfers: TransfersView()
                case .sharedExpenses: SharedExpensesView()
                case .budgets: BudgetsView()
                case .categories: ManageCategoriesView()
                case .rules: ManageRulesView()
                case .transferRoutes: ManageTransferRoutesView()
                case .spaces: ManageSpacesView()
                case .groups: ManageGroupsView()
                case .trading212: Trading212SettingsView()
                case .fundPrices: FundPricesSettingsView()
                case .claude: ClaudeSettingsView()
                }
            }
            .navigationDestination(for: Connection.self) { ConnectionDetailView(connection: $0) }
            .task(id: PendingNavigation.shared.connectionId) { openPendingConnection() }
            .navigationDestination(for: SharedExpenseGroup.self) { SharedExpenseGroupDetailView(group: $0) }
            .sheet(isPresented: $movingAStart) {
                MoveMonthStartSheet(cycle: cycle) { start in
                    oneOffStartsStored = CycleSettings.storing(oneOffStarts + [start])
                }
            }
            #if DEBUG
            .task { applyHook() }
            #endif
        }
    }

    @Environment(\.modelContext) private var modelContext

    private func openPendingConnection() {
        guard let id = PendingNavigation.shared.connectionId else { return }
        PendingNavigation.shared.connectionId = nil
        guard let connection = try? modelContext.fetch(FetchDescriptor<Connection>()).first(where: { $0.id == id }) else { return }
        path = NavigationPath()
        path.append(SettingsDestination.connections)
        path.append(connection)
    }

    // Disabling the lock is itself a privileged action: without this, anyone holding the
    // unlocked phone could silently strip the protection. Fails closed — if authentication
    // can't run or fails, the lock stays on.
    private func confirmDisable() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            requireUnlock = true
            return
        }
        Task {
            let success = (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Confirm turning off the app lock"
            )) ?? false
            if !success { requireUnlock = true }
        }
    }

    private var oneOffStarts: [Date] { CycleSettings.oneOffStarts(oneOffStartsStored) }

    private var cycle: CoreLogic.Dashboard.Cycle {
        .init(startDay: cycleStartDay, startsEarlyOnWeekends: startsEarlyOnWeekends, oneOffStarts: oneOffStarts)
    }

    private static let day = utcFormatter("d MMM yyyy")
    private static let shortDay = utcFormatter("d MMM")

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = format
        return f
    }

    private var cycleFooter: String {
        let moved = " A moved start changes one month only, for a salary paid off schedule: that month runs to its usual end, and the month before ends the day before."
        guard cycleStartDay != 1 else { return "Income and expenses are grouped by calendar month." + moved }
        var text = "Income and expenses are grouped from the \(Self.ordinal(cycleStartDay)) to the day before the \(Self.ordinal(cycleStartDay)) of the next month."
        if startsEarlyOnWeekends {
            text += " When the \(Self.ordinal(cycleStartDay)) is a Saturday or Sunday, the month starts on the Friday before, like a salary paid early."
        }
        return text + " Every past month is recalculated." + moved
    }

    private static func ordinal(_ day: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: day as NSNumber) ?? "\(day)"
    }

    private static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    #if DEBUG
    private func applyHook() {
        switch UITestHooks.presentSheet {
        case "connections", "eb-setup", "connect-bank", "eb-sync-all":
            path.append(SettingsDestination.connections)
        case "connection-detail":
            path.append(SettingsDestination.connections)
            if let first = debugConnections.first { path.append(first) }
        case "transfers": path.append(SettingsDestination.transfers)
        case "trading212": path.append(SettingsDestination.trading212)
        case "fund-prices": path.append(SettingsDestination.fundPrices)
        case "automations": path.append(SettingsDestination.automations)
        case "claude": path.append(SettingsDestination.claude)
        case "spaces", "space-edit": path.append(SettingsDestination.spaces)
        case "groups", "group-edit": path.append(SettingsDestination.groups)
        case "categories", "category-edit": path.append(SettingsDestination.categories)
        case "rules", "rule-edit": path.append(SettingsDestination.rules)
        case "routes", "route-edit": path.append(SettingsDestination.transferRoutes)
        case "budgets", "budget-edit": path.append(SettingsDestination.budgets)
        case "shared": path.append(SettingsDestination.sharedExpenses)
        case "shared-detail":
            path.append(SettingsDestination.sharedExpenses)
            if let first = debugGroups.first { path.append(first) }
        default: break
        }
    }
    #endif
}

enum SettingsDestination: Hashable {
    case connections, transfers, sharedExpenses, budgets, categories, rules, transferRoutes, spaces, groups, trading212, fundPrices, automations, claude
}

// A Settings navigation row: teal icon chip + title, pushing a destination.
private struct SettingsLinkRow: View {
    let title: String
    let systemImage: String
    let destination: SettingsDestination

    var body: some View {
        NavigationLink(value: destination) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(systemName: systemImage)
                Text(title)
            }
        }
    }
}

// Brand identity block at the top of Settings.
private struct SettingsBrandHeader: View {
    let version: String

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            AppIconTile(size: 60)
            Text("Odyssey Finance")
                .font(.title3.weight(.semibold))
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Odyssey Finance, version \(version)")
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .modelContainer(PreviewData.container)
}
#endif

// Picks the day one month starts on instead, and says which usual start it replaces.
private struct MoveMonthStartSheet: View {
    let cycle: CoreLogic.Dashboard.Cycle
    let onMove: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Date()

    private var start: Date { CycleSettings.utcDay(picked) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Month Starts", selection: $picked, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                } footer: {
                    Text("The month that usually starts on \(Self.day.string(from: cycle.usualStart(movedTo: start))) starts on \(Self.day.string(from: start)) instead.")
                }
            }
            .navigationTitle("Move a Month's Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onMove(start)
                        dismiss()
                    }
                }
            }
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}
