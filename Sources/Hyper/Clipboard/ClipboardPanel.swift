import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum PanelFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    /// The batch queue, in the order it will be dispensed. Not a filter over kinds like
    /// the rest — see `ClipboardPanelModel.queueOrdered(_:)`.
    case queue
    case text
    case url
    case image
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部"
        case .pinned: return "收藏"
        case .queue: return "队列"
        case .text: return "文本"
        case .url: return "链接"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .pinned: return "star"
        case .queue: return "text.append"
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }

    var kind: ClipKind? {
        switch self {
        case .all, .pinned, .queue: return nil
        case .text: return .text
        case .url: return .url
        case .image: return .image
        case .files: return .files
        }
    }
}

/// A preview's text, and whether it is all of it.
struct PreviewText {
    var body: String
    var truncated: Bool
}

/// Everything one read of an entry's payload yields for the preview pane.
///
/// The two halves used to be fetched by two calls, which meant two `Data(contentsOf:)`
/// and two plist decodes of the same file for every styled row the pointer crossed.
struct ClipPreviewLoad {
    var text: PreviewText?
    /// The RTF bytes, for the entries that are styled and small enough to render.
    var rich: Data?
}

/// A failed paste translated into language the panel can act on.
///
/// `ClipboardOperationResult` deliberately stays an exact account of the transaction.
/// This is its presentation counterpart: it counts per-item failures for the user and
/// says whether System Settings is a useful way out, without making the SwiftUI layer
/// understand pasteboard or Core Graphics errors.
struct ClipboardPasteIssue: Equatable {
    let title: String
    let detail: String
    let offersAccessibilitySettings: Bool
    let offersSkipInvalid: Bool

    init(
        title: String, detail: String, offersAccessibilitySettings: Bool,
        offersSkipInvalid: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.offersAccessibilitySettings = offersAccessibilitySettings
        self.offersSkipInvalid = offersSkipInvalid
    }

    static func make(from result: ClipboardOperationResult) -> ClipboardPasteIssue? {
        guard let failure = result.failure else { return nil }

        switch failure {
        case .accessibilityPermissionDenied:
            return ClipboardPasteIssue(
                title: "无法粘贴：需要辅助功能权限",
                detail: "内容和选择都已保留。打开系统设置并允许 Hyper 控制电脑，然后回到这里重新粘贴。",
                offersAccessibilitySettings: true
            )
        case .preflightFailed:
            var missingPayload = 0
            var oversized = 0
            var missingRecord = 0
            var incompatible = 0
            var ready = 0
            for item in result.items {
                switch item.state {
                case .ready, .completed:
                    ready += 1
                case .failed(let itemFailure):
                    switch itemFailure {
                    case .missingPayload: missingPayload += 1
                    case .oversized: oversized += 1
                    case .missingRecord: missingRecord += 1
                    }
                case .failedPreflight(.incompatiblePayload):
                    incompatible += 1
                }
            }
            let failed = missingPayload + oversized + missingRecord + incompatible
            var reasons: [String] = []
            if missingPayload > 0 { reasons.append("缺失内容 " + String(missingPayload) + " 条") }
            if oversized > 0 { reasons.append("超过大小限制 " + String(oversized) + " 条") }
            if missingRecord > 0 { reasons.append("队列记录缺失 " + String(missingRecord) + " 条") }
            if incompatible > 0 {
                reasons.append("格式不兼容、无法合并为文本 " + String(incompatible) + " 条")
            }
            let total = max(result.items.count, failed)
            let count = total > 0
                ? "所选 " + String(total) + " 条中有 " + String(failed) + " 条不可用"
                : "所选内容不可用"
            let reason = reasons.isEmpty ? "内容无法读取" : reasons.joined(separator: "，")
            return ClipboardPasteIssue(
                title: "未粘贴：" + count,
                detail: reason + "。默认整批已取消，未粘贴任何条目；选择仍保留。",
                offersAccessibilitySettings: false,
                offersSkipInvalid: ready > 0 && failed > 0
            )
        case .targetUnavailable:
            return ClipboardPasteIssue(
                title: "未粘贴：目标应用不可用",
                detail: "内容和选择都已保留。重新打开目标应用或切回要粘贴的位置后再试。",
                offersAccessibilitySettings: false
            )
        case .pasteboardWrite(let placement):
            let reason: String
            switch placement {
            case .emptyPayload: reason = "这条记录没有可写入的数据"
            case .plainTextUnavailable: reason = "这条记录没有可用的纯文本格式"
            case .incompatiblePayload(let index):
                reason = "第 " + String(index + 1) + " 条内容无法合并为文本"
            case .pasteboardRejected: reason = "系统剪贴板拒绝了这次写入"
            }
            return ClipboardPasteIssue(
                title: "未粘贴：无法准备剪贴板",
                detail: reason + "。原剪贴板未被当作成功处理，选择仍保留，可调整后重试。",
                offersAccessibilitySettings: false
            )
        case .eventDelivery:
            return ClipboardPasteIssue(
                title: "未粘贴：系统未能发送粘贴指令",
                detail: "内容和选择都已保留。确认辅助功能权限仍然开启，并回到目标应用后重试。",
                offersAccessibilitySettings: true
            )
        case .operationInProgress:
            return ClipboardPasteIssue(
                title: "暂时无法粘贴：上一项仍在处理",
                detail: "当前内容和选择都已保留。等待上一项完成后再试。",
                offersAccessibilitySettings: false
            )
        case .emptySelection:
            return ClipboardPasteIssue(
                title: "没有可粘贴的内容",
                detail: "请选择至少一条完整记录后再试。",
                offersAccessibilitySettings: false
            )
        }
    }
}

// MARK: - Grouping

/// The bands the list is divided into.
///
/// Purely a drawing decision: the headers are inserted *inside* the same `ForEach` that
/// walks `results`, so a row's index in the flat array — which is what the selection,
/// the keyboard navigation and ⌘1-9 all speak in — is untouched by them. Which row opens
/// which band is worked out here rather than in the view: a `body` that asked per row
/// would run a calendar lookup for every visible row of every frame of a hover.
private enum ClipGroup {
    case pinned
    case today
    case yesterday
    case thisWeek
    case earlier

    var title: String {
        switch self {
        case .pinned: return "收藏"
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .thisWeek: return "本周"
        case .earlier: return "更早"
        }
    }
}

/// The three instants that decide which band a date falls in.
///
/// Built once per list rather than once per row. `Calendar.current` alone is a lookup,
/// and `isDateInToday` and `dateInterval(of:)` do real work each time they are asked;
/// reduced to three comparisons against dates worked out up front, classifying a
/// thousand rows costs nothing worth measuring.
private struct ClipGroupBounds {
    let todayStart: Date
    let yesterdayStart: Date
    let weekStart: Date

    init(now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        todayStart = today
        yesterdayStart = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        // The current calendar week, which is what the label promises — a rolling seven
        // days would file last Sunday under 本周 on a Monday morning.
        weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
    }

    /// Pinned entries sort above everything else regardless of age, so they are a band
    /// of their own rather than being scattered through the days they were copied on.
    func group(of record: ClipRecord) -> ClipGroup {
        if record.pinned { return .pinned }
        let date = record.createdAt
        if date >= todayStart { return .today }
        if date >= yesterdayStart { return .yesterday }
        if date >= weekStart { return .thisWeek }
        return .earlier
    }
}

/// Whether the panel has ever introduced itself, remembered across launches.
///
/// `UserDefaults` rather than the app's own configuration file, which is the only other
/// place this could live. That file is a document the user is invited to open and edit,
/// and every line in it is a decision someone made; this is a single bit of "has this
/// already happened", which is nobody's setting and would only be clutter there. The
/// bundle identifier is fixed, so the standard suite is a stable place to keep it.
enum ClipboardOnboarding {
    private static let key = "clipboardOnboardingShown"

    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: key) }

    /// Marked the moment the overlay goes up rather than when it is dismissed. A panel
    /// closed by clicking away dismisses nothing, and a first-run card that came back on
    /// every opening until it was clicked would be the opposite of "once".
    static func markShown() { UserDefaults.standard.set(true, forKey: key) }
}

/// State for the panel. Recomputes the visible list whenever the query, the filter or
/// the underlying history changes, and keeps the selection pinned to a sensible row.
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published var filter: PanelFilter = .all { didSet { refresh(resettingSelection: true) } }
    @Published private(set) var results: [ClipRecord] = []
    /// How many rows each pill would show under the query in the field — the number the
    /// pill wears. Worked out once per search rather than per pill; see `refresh`.
    @Published private(set) var filterCounts: [PanelFilter: Int] = [:]
    @Published var selectedIndex = 0
    @Published private(set) var checked: Set<UUID> = []
    @Published private(set) var queueCount = 0
    /// The queue as a set, so a row can ask whether it is in it without walking the
    /// whole order — which the list did once per row per frame.
    @Published private(set) var queuedIDs: Set<UUID> = []
    /// Row index → the title of the band that row opens, or nothing when it continues
    /// the band above. Worked out here, once per list, rather than in the view — see
    /// `ClipGroupBounds`.
    @Published private(set) var groupHeaders: [Int: String] = [:]
    /// The shortcut sheet over the list. Opened with `?`, and by the hint bar's own `?`.
    @Published var showingShortcuts = false
    /// The first-run card over the list. Shown once, ever — see `ClipboardOnboarding`.
    @Published private(set) var showingOnboarding = false

    /// The last paste failure that still needs the user's attention. It lives in the
    /// panel rather than in a transient HUD so the explanation and its repair actions
    /// remain reachable by pointer, keyboard and VoiceOver.
    @Published private(set) var pasteIssue: ClipboardPasteIssue?

    /// The row currently being dragged out of the list, or nil.
    ///
    /// Set the instant `.onDrag` hands a provider over, cleared when the button comes back
    /// up. Both of the panel's drop targets read it: the 收藏 reorder needs to know which
    /// row is in flight, and 拖入即存 has to ignore a drag that started here rather than
    /// saving the list's own content back into it.
    @Published private(set) var draggingID: UUID?

    /// Whether the drag currently over the list came out of this panel.
    ///
    /// Worked out once per crossing, in `dropEntered`, rather than on every pointer move:
    /// reading it means asking `DropInfo` for its item providers, which rebuilds them off
    /// the pasteboard each time, and `dropUpdated` is asked at the frame rate. Cleared on
    /// the way out of a target so the next drag is judged on its own.
    private(set) var dragIsOwn = false

    /// Whether a drop actually landed in the list during the current resign exemption —
    /// see `ClipboardPanelController.endDragExemption`, which is the only reader.
    private(set) var dropCompletedDuringExemption = false

    /// Whether the screen has room for the preview window beside the list. Written by the
    /// controller from `position(_:)`, because placement is the only thing that knows.
    /// The hint bar and the shortcut sheet stop advertising `→` when it is false — a key
    /// that visibly does nothing is worse than one that was never mentioned.
    @Published var previewAvailable = true

    /// Whether something is being held over the list, for the border that says so.
    @Published private(set) var dropTargeted = false
    private var dropHighlightWork: DispatchWorkItem?
    /// Mirrors the system's "reduce motion" setting, so the view layer can drop its
    /// animations too. Written by the controller on every `show()` rather than read
    /// here: the setting can change while the app is running, and the panel is the one
    /// place that has a natural moment to re-read it.
    @Published var reduceMotion = false

    /// What ↩ does, as the settings have it. Written by the controller on every `show()`
    /// for the same reason `reduceMotion` is: the panel reads the setting fresh each time
    /// it opens, and the hint bar and the shortcut sheet have to say whichever it is.
    @Published var returnPastes = true

    /// The "now" every relative timestamp in the list is measured against.
    ///
    /// Rows would otherwise keep saying "刚刚" for as long as the panel stays open, which
    /// is wrong within a minute of opening it. Republished on a timer so the subtitles
    /// re-derive themselves; it doubles as the reference date the date grouping uses, so
    /// a row cannot be under 今天 while its subtitle has already moved on.
    @Published private(set) var clockTick = Date() {
        didSet { rebuildGroupHeaders() }
    }
    private var clockTimer: Timer?

    /// Whether the panel is on screen, maintained by the controller. Everything the
    /// model does is in aid of drawing a list, so with nothing drawing it there is
    /// nothing worth recomputing — see the observers in `init`.
    private var isPanelVisible = false
    /// Set when a change arrived with the panel away, and the list it would have
    /// rebuilt is therefore stale. Cleared on the way back in, where `reset()` re-runs
    /// the search from scratch and settles every deferred change at once.
    private var needsRefreshOnShow = false
    /// Set while the list is being built for a panel that is only now appearing. The
    /// window fades and swells in around it, and a screenful of rows sliding in under
    /// that reads as a stutter rather than as an arrival.
    private var suppressResultAnimation = false

    /// Bumped only when the selection moved by keyboard. The pointer moves it too, and
    /// scrolling for that would pull the hovered row out from under the pointer — which
    /// lands a different row there, which hovers, which scrolls again.
    @Published private(set) var scrollTick = 0

    /// Where the pointer was when the panel opened, and whether it has since moved.
    ///
    /// The panel usually opens directly under the pointer, so on the very first frame
    /// some row is already hovered. Letting that row take the selection would mean ↩
    /// pastes whatever the pointer happened to be resting on rather than the newest
    /// entry, so hovering only starts steering once the pointer has actually moved.
    private var openPointer = NSEvent.mouseLocation
    private var hoverArmed = false

    /// The row the preview window is showing. Sticky: it survives the pointer crossing
    /// the gap between the two windows, so reaching for the preview does not empty it
    /// on the way.
    @Published private(set) var previewIndex: Int?
    @Published private(set) var pointerOnList = false
    @Published private(set) var pointerInPreview = false

    /// Held open by `→` rather than by the pointer. Hovering is the only way the preview
    /// could be summoned, which meant someone driving the panel from the keyboard alone
    /// never saw it at all; this is the keyboard's own way in, and it follows the
    /// selection instead of the pointer for as long as it lasts.
    @Published private(set) var previewPinned = false

    /// The preview is open while the pointer is on one of the two windows, or for as
    /// long as the keyboard has asked for it. The two coexist: releasing the pin with a
    /// pointer still on the list leaves the ordinary hover preview behind it.
    var previewOpen: Bool { pointerOnList || pointerInPreview || previewPinned }

    var previewRecord: ClipRecord? {
        guard let previewIndex, results.indices.contains(previewIndex) else { return nil }
        return results[previewIndex]
    }

    /// What the current `results` were matched by, for the highlighting in the rows and
    /// the preview. Deliberately the terms the search *ran with*, not the ones in the
    /// field right now, so a debounced result never highlights a half-typed word.
    @Published private(set) var highlightTerms: [String] = []

    /// Rows whose only hit is past the end of their preview, mapped to a snippet of the
    /// text around it.
    @Published private(set) var contexts: [UUID: String] = [:]

    /// Where ↩ will send the paste: the application that was in front when the panel
    /// opened. Written by the controller, which is the only thing that knows — see
    /// `ClipboardPanelController.previousApp`. Nil when there is nothing worth naming,
    /// which is also how the badge is switched off.
    @Published private(set) var targetAppName: String?
    @Published private(set) var targetAppIcon: NSImage?

    private unowned let manager: ClipboardManager
    private var observers: [NSObjectProtocol] = []

    private let searchQueue = DispatchQueue(
        label: "com.indincys.hyper.clipboard.panelsearch", qos: .userInitiated
    )
    private var pendingSearch: DispatchWorkItem?
    /// Discards the answer to a query that is no longer the current one; results can
    /// come back out of order once the scan is asynchronous.
    private var searchToken: UInt64 = 0

    /// What a cached search answer is an answer *to*. The tab is deliberately not part of
    /// it: the search runs without the tab's narrowing — see `refresh`.
    private struct SearchKey: Equatable {
        var terms: [String]
        var generation: UInt64
    }

    /// The last search outcome, so a change that cannot have changed it — a tab switch,
    /// above all — does not re-run it. One entry: the query and the history move forward,
    /// and an older answer is an answer to a question nobody is asking again.
    private var cachedOutcome: (key: SearchKey, outcome: ClipSearchOutcome)?

    init(manager: ClipboardManager) {
        self.manager = manager
        syncQueueState()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ClipboardManager.historyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Every system-wide copy posts this, panel or no panel — and a rebuild is a
            // snapshot of the whole history, a search over it and half a dozen published
            // writes. With nothing on screen to show the result to, the work is recorded
            // as owed instead and `panelWillShow()` settles it in one pass.
            guard self.isPanelVisible else {
                self.needsRefreshOnShow = true
                return
            }
            self.refresh(resettingSelection: false)
        })
        observers.append(center.addObserver(
            forName: ClipboardManager.queueChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // The count and the membership set are cheap and are read from outside the
            // list too (the badge, the row's own marker), so they stay current either way.
            self.syncQueueState()
            guard self.isPanelVisible else {
                self.needsRefreshOnShow = true
                return
            }
            // On the queue tab the queue *is* the list, so a change to it is a change to
            // the rows — the badge alone would leave a removed entry sitting there.
            if self.filter == .queue { self.refresh(resettingSelection: false) }
        })
    }

    deinit {
        pendingSearch?.cancel()
        dropHighlightWork?.cancel()
        clockTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Dragging and dropping

    func beginRowDrag(_ id: UUID) {
        draggingID = id
    }

    func endRowDrag() {
        guard draggingID != nil else { return }
        draggingID = nil
    }

    /// Whether the 收藏 band can be rearranged by dragging right now.
    ///
    /// Only on the 收藏 tab with nothing typed, because only there is the list *exactly*
    /// the band in its stored order — so a row's place on screen is its place in the band
    /// and the reorder needs no translation. Under a query the list is a subset in
    /// relevance order, and dropping a row onto another would be rearranging something the
    /// list is not showing.
    var canReorderPinned: Bool { filter == .pinned && query.isEmpty }

    /// Where the row being dragged currently sits in the list.
    var draggingIndex: Int? {
        guard let draggingID else { return nil }
        return results.firstIndex { $0.id == draggingID }
    }

    /// What `dropEntered` worked out about the drag now over the list.
    func noteDragIsOwn(_ own: Bool) {
        dragIsOwn = own
    }

    /// A drop was taken. Only read by the exemption that a resign started — see
    /// `ClipboardPanelController.endDragExemption`.
    func noteDropCompleted() {
        dropCompletedDuringExemption = true
    }

    func clearDropCompleted() {
        dropCompletedDuringExemption = false
    }

    func dropTargetEntered() {
        dropHighlightWork?.cancel()
        dropHighlightWork = nil
        dropTargeted = true
    }

    /// Deferred, like the preview's own hide and for the same shape of reason: the list
    /// and each of its rows is a drop target, so crossing from one row to the next sends
    /// an exit before the next entry and the border would strobe all the way down the
    /// list. A beat's grace turns that back into one steady frame.
    func dropTargetExited() {
        // Recomputed on the way back in. Left set, a foreign drag arriving after one of
        // our own rows had passed through would be refused as "ours" by the first
        // `validateDrop`, which runs before `dropEntered` gets to correct it.
        dragIsOwn = false
        dropHighlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dropHighlightWork = nil
            self?.dropTargeted = false
        }
        dropHighlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// The drag is over, one way or the other.
    func dropTargetFinished() {
        dragIsOwn = false
        dropHighlightWork?.cancel()
        dropHighlightWork = nil
        guard dropTargeted else { return }
        dropTargeted = false
    }

    /// Any key or click takes the first-run card away. Reports whether there was one to
    /// take, because the key that dismissed it goes on to do its ordinary job.
    @discardableResult
    func dismissOnboarding() -> Bool {
        guard showingOnboarding else { return false }
        showingOnboarding = false
        return true
    }

    /// The queue, as the panel reads it: how many, and which ones.
    private func syncQueueState() {
        queueCount = manager.queue.count
        queuedIDs = Set(manager.queue.ids)
    }

    /// Runs only while the panel is on screen — there is nothing to keep fresh once it
    /// is gone, and `reset()` re-reads the clock on the way back in anyway.
    func startClock() {
        stopClock()
        clockTick = Date()
        // Scheduled in `.common` rather than through `scheduledTimer`: a menu or a
        // scroll puts the run loop into a tracking mode, and a default-mode timer would
        // simply stop ticking for as long as that lasted.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.clockTick = Date()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    var selected: ClipRecord? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// The rows an action applies to: the ticked ones if there are any, otherwise
    /// just the highlighted row.
    var actionTargets: [ClipRecord] {
        guard !checked.isEmpty else { return selected.map { [$0] } ?? [] }
        // Ordered as displayed, not as ticked, so a merge comes out in list order.
        return results.filter { checked.contains($0.id) }
    }

    /// Typing a word should not run one full-text scan per keystroke. Clearing the
    /// field skips the wait — an empty query is a plain array walk, and anything but an
    /// instant return there reads as the panel having got stuck.
    private func scheduleSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            refresh(resettingSelection: true)
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.refresh(resettingSelection: true) }
        pendingSearch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    func refresh(resettingSelection: Bool) {
        // Deliberately *without* the tab's own narrowing. Every pill wears the number of
        // rows it would show under the query in the field, and one search that answers
        // for all seven costs far less than seven that each answer for one: the text scan
        // is the expensive half and is exactly the half they would repeat. Cutting the
        // open tab out of that answer is a pass over an array — see `narrowed(_:)`.
        let request = ClipSearchRequest(
            terms: ClipSearch.terms(from: query), kind: nil, pinnedOnly: false
        )
        // The search is a pure function of the terms and the history, and the store bumps
        // its generation on every change to the latter — so switching tabs, which changes
        // neither, can reuse the last answer instead of scanning the whole history again
        // for a result it already has. Only `narrowed` and the counts are redone, which is
        // one pass over an array. Tab is the hot case: Tab-Tab-Tab through seven pills
        // with a query in the field was seven full-text scans.
        let key = SearchKey(terms: request.terms, generation: manager.store.generation)
        searchToken &+= 1
        let token = searchToken

        if let cached = cachedOutcome, cached.key == key {
            apply(cached.outcome, resettingSelection: resettingSelection)
            return
        }

        // Taken here, on the main thread, because the store's state belongs to it.
        // Both halves are copy-on-write, so this is a retain rather than a copy.
        let snapshot = manager.store.searchSnapshot()

        // Filtering by kind alone never touches the text, so it stays synchronous and
        // the list is already right by the time the pill finishes animating.
        guard !request.terms.isEmpty else {
            let outcome = ClipSearch.run(request, in: snapshot)
            cachedOutcome = (key, outcome)
            apply(outcome, resettingSelection: resettingSelection)
            return
        }

        searchQueue.async { [weak self] in
            let outcome = ClipSearch.run(request, in: snapshot)
            DispatchQueue.main.async {
                guard let self, self.searchToken == token else { return }
                self.cachedOutcome = (key, outcome)
                self.apply(outcome, resettingSelection: resettingSelection)
            }
        }
    }

    /// Reduces a search outcome to the queued entries, in dispensing order.
    ///
    /// Done here rather than in `ClipSearch` because the queue is not a property of a
    /// record: the search stays a pure function of the history, and the tab that reads
    /// it differently does the reordering itself. With a query in the field this is the
    /// intersection of the two, which keeps searching inside the queue working exactly
    /// as it does everywhere else.
    private func queueOrdered(_ records: [ClipRecord]) -> [ClipRecord] {
        var byID: [UUID: ClipRecord] = [:]
        for record in records { byID[record.id] = record }
        return manager.queue.ids.compactMap { byID[$0] }
    }

    /// The open tab's own cut of a search that ran without it.
    private func narrowed(_ records: [ClipRecord]) -> [ClipRecord] {
        switch filter {
        case .all: return records
        case .pinned: return records.filter(\.pinned)
        case .queue: return queueOrdered(records)
        case .text, .url, .image, .files:
            guard let kind = filter.kind else { return records }
            return records.filter { $0.kind == kind }
        }
    }

    /// One walk over the matches for all seven pills. `.all` is the whole set by
    /// definition, and the queue counts what it has in common with it — the queue tab is
    /// an intersection, so its pill has to be one too or the number would promise rows
    /// the tab does not show.
    private static func filterCounts(
        in records: [ClipRecord], queued: Set<UUID>
    ) -> [PanelFilter: Int] {
        var pinned = 0
        var inQueue = 0
        var byKind: [ClipKind: Int] = [:]
        for record in records {
            if record.pinned { pinned += 1 }
            if queued.contains(record.id) { inQueue += 1 }
            byKind[record.kind, default: 0] += 1
        }
        var counts: [PanelFilter: Int] = [.all: records.count, .pinned: pinned, .queue: inQueue]
        for filter in PanelFilter.allCases {
            guard let kind = filter.kind else { continue }
            counts[filter] = byKind[kind] ?? 0
        }
        return counts
    }

    private func apply(_ outcome: ClipSearchOutcome, resettingSelection: Bool) {
        // Ahead of the counts, one of which is read off the queue's membership.
        syncQueueState()
        let rows = narrowed(outcome.records)
        // Rows arriving and leaving are worth a transition; a list built for a panel that
        // is not on screen, or one drawn under "reduce motion", is not. Nor is the first
        // list of an appearance — see `panelWillShow()`.
        let motion = isPanelVisible && !reduceMotion && !suppressResultAnimation
        withAnimation(motion ? .easeOut(duration: 0.15) : nil) {
            results = rows
        }
        filterCounts = Self.filterCounts(in: outcome.records, queued: queuedIDs)
        highlightTerms = outcome.terms
        contexts = outcome.contexts
        checked = checked.intersection(Set(results.map(\.id)))
        rebuildGroupHeaders()
        if resettingSelection {
            selectedIndex = 0
            scrollTick &+= 1
        } else {
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
        }
        syncPinnedPreview()
    }

    /// Bands are drawn from the results and the clock, so they are rebuilt wherever
    /// either moves — after a search, and on every tick of the panel's clock.
    ///
    /// Suppressed while a search is on: results come back in relevance order, where a
    /// date boundary is noise rather than structure. Read from the terms the *results*
    /// were matched by rather than from the field, so a header does not flicker away
    /// during the debounce and back again when the answer disagrees. Suppressed on the
    /// queue tab for a different reason — the order there is the paste order, and "今天"
    /// cutting through it would suggest a grouping the list does not have.
    private func rebuildGroupHeaders() {
        guard highlightTerms.isEmpty, filter != .queue, !results.isEmpty else {
            if !groupHeaders.isEmpty { groupHeaders = [:] }
            return
        }
        let bounds = ClipGroupBounds(now: clockTick)
        var headers: [Int: String] = [:]
        var previous: ClipGroup?
        for (index, record) in results.enumerated() {
            let group = bounds.group(of: record)
            if group != previous { headers[index] = group.title }
            previous = group
        }
        groupHeaders = headers
    }

    func reset() {
        pendingSearch?.cancel()
        pendingSearch = nil
        query = ""
        // The tab survives the panel going away, because which kind of thing you are
        // looking for rarely changes between two openings — and reopening onto 全部 every
        // time made the pills something to re-set rather than something to set. The query
        // and the multi-selection do not survive: those are one errand each.
        //
        // What it does not survive is having nothing left in it; that is settled below,
        // once the list has been rebuilt and there is an answer to look at.
        syncQueueState()
        checked = []
        showingShortcuts = false
        showingOnboarding = false
        pasteIssue = nil
        endRowDrag()
        dropTargetFinished()
        clearDropCompleted()
        selectedIndex = 0
        openPointer = NSEvent.mouseLocation
        hoverArmed = false
        previewIndex = nil
        previewPinned = false
        pointerOnList = false
        pointerInPreview = false
        clockTick = Date()
        refresh(resettingSelection: true)
        // Any page can be emptied while the panel is away: the queue by dispensing its
        // last row, every other one by the retention sweep or by 清空历史. Coming back to
        // an empty page instead of the history reads as the history having been lost, so
        // a remembered tab is only kept while it still has something in it. Decided from
        // `results` rather than from the counts, and safe to read here because the query
        // is empty by now — which is the one case where the search above ran
        // synchronously. Assigning the filter re-runs it.
        if results.isEmpty, filter != .all { filter = .all }
    }

    /// What ↩ will paste into, as the header's badge draws it.
    func setPasteTarget(name: String?, icon: NSImage?) {
        targetAppName = name
        targetAppIcon = icon
    }

    func presentPasteIssue(_ result: ClipboardOperationResult) {
        pasteIssue = ClipboardPasteIssue.make(from: result)
    }

    func dismissPasteIssue() {
        pasteIssue = nil
    }

    func noteAccessibilityPermissionGranted() {
        guard pasteIssue?.offersAccessibilitySettings == true else { return }
        pasteIssue = ClipboardPasteIssue(
            title: "辅助功能权限已开启",
            detail: "内容、查询和选择仍在原位。现在可以重新粘贴。",
            offersAccessibilitySettings: false
        )
    }

    /// The panel is on its way up. `reset()` re-runs the search against a fresh
    /// snapshot, so it is also the refresh every change deferred while the panel was
    /// away was waiting for — hence the flag being cleared rather than acted on.
    func panelWillShow() {
        isPanelVisible = true
        needsRefreshOnShow = false
        // `reset()`'s refresh is synchronous — it runs with an empty query — so this is
        // lifted again by the time anything else can reach the model.
        suppressResultAnimation = true
        reset()
        suppressResultAnimation = false
        // After `reset()`, which clears the layer these two share: the very first
        // appearance should be showing the card and not also the shortcut sheet.
        if ClipboardOnboarding.shouldShow {
            showingOnboarding = true
            ClipboardOnboarding.markShown()
        }
        startClock()
    }

    /// The panel has gone. Nothing is being drawn from here until it comes back.
    func panelDidHide() {
        isPanelVisible = false
        // A drag can outlive the list it started in — the panel closes the moment a row is
        // dropped somewhere else — and neither of these may be left set behind it, or the
        // next appearance would open believing a drag were still in progress.
        endRowDrag()
        dropTargetFinished()
        stopClock()
    }

    // MARK: - Selection

    func move(by delta: Int, extending: Bool) {
        guard !results.isEmpty else { return }
        let previous = selectedIndex
        selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
        scrollTick &+= 1
        syncPinnedPreview()
        guard extending, selectedIndex != previous else { return }
        // A jump of more than one row — a page, or an end — has to tick everything it
        // passed over, or ⇧PgDn would select two rows ten apart and nothing between.
        for index in min(previous, selectedIndex)...max(previous, selectedIndex) {
            checked.insert(results[index].id)
        }
    }

    func moveToEdge(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = delta < 0 ? 0 : results.count - 1
        scrollTick &+= 1
        syncPinnedPreview()
    }

    /// A preview held open by the keyboard shows the row the keyboard is on. Called
    /// wherever the selection or the list itself moves; a no-op while the preview is
    /// merely being hovered, which is the pointer's business.
    private func syncPinnedPreview() {
        guard previewPinned else { return }
        previewIndex = results.indices.contains(selectedIndex) ? selectedIndex : nil
    }

    /// `→`: hold the preview open on the selected row.
    func pinPreview() {
        guard !results.isEmpty else { return }
        previewPinned = true
        previewIndex = selectedIndex
    }

    /// `←`: let it go. The pointer may still be keeping it up, which is intentional.
    func unpinPreview() {
        previewPinned = false
    }

    /// The pointer came to rest on a row. Opens the preview on it, and takes the
    /// selection with it — but only once the pointer has really moved since the panel
    /// opened.
    func hover(_ index: Int) {
        guard results.indices.contains(index) else { return }
        previewIndex = index
        pointerOnList = true
        if !hoverArmed {
            let now = NSEvent.mouseLocation
            guard abs(now.x - openPointer.x) > 2 || abs(now.y - openPointer.y) > 2 else { return }
            hoverArmed = true
        }
        selectedIndex = index
    }

    /// The pointer left a row. `previewIndex` deliberately stays put: the controller
    /// closes the preview on a short delay, and the pointer is over neither window
    /// while it crosses the gap towards the preview.
    func hoverEnded(_ index: Int) {
        guard previewIndex == index else { return }
        pointerOnList = false
    }

    func setPointerInPreview(_ inside: Bool) {
        pointerInPreview = inside
    }

    /// A click selects unconditionally — it is a deliberate act, unlike a hover.
    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        hoverArmed = true
        selectedIndex = index
        syncPinnedPreview()
    }

    func toggleChecked(_ id: UUID) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func clearChecked() {
        checked.removeAll()
    }

    /// Whether every visible row is ticked — which is also what makes ⌘A a toggle rather
    /// than a one-way trip.
    var allChecked: Bool { !results.isEmpty && checked.count == results.count }

    /// ⌘A. Over the rows currently on screen, not over the whole history: what the
    /// batch bar then acts on is what the list is showing, which is the only set the
    /// user can see and check.
    func toggleSelectAll() {
        guard !results.isEmpty else { return }
        if allChecked {
            checked.removeAll()
        } else {
            checked = Set(results.map(\.id))
        }
    }

    func cycleFilter(backwards: Bool = false) {
        let all = PanelFilter.allCases
        guard let index = all.firstIndex(of: filter) else { return }
        let next = (index + (backwards ? -1 : 1) + all.count) % all.count
        filter = all[next]
    }

    func thumbnail(for record: ClipRecord) -> NSImage? {
        manager.store.thumbnail(for: record)
    }

    /// Past this the preview is cut short.
    ///
    /// SwiftUI lays out every character of a `Text` before it can draw the first line
    /// of it, and the cost grows faster than the length: measured on this pane, 7,650
    /// characters (a 20 KB entry) took 340ms, 4,000 took 96ms, 2,000 took 28ms and
    /// 1,200 took 13ms. At 340ms on the main thread the panel simply stops responding,
    /// and it was paying that on every selection change.
    ///
    /// 2,000 characters is about two screenfuls here — more than enough to recognise an
    /// entry by, which is all a preview owes anyone.
    private static let previewCharacterCap = 2_000

    private static let previewQueue = DispatchQueue(
        label: "com.indincys.hyper.clip.preview", qos: .userInitiated
    )

    /// Past this an entry's RTF is not rendered as styled text at all.
    ///
    /// `NSAttributedString(rtf:)` is main-thread-only — it is AppKit's own parser — so
    /// the whole cost lands on the frame that draws the preview. A quarter of a megabyte
    /// of RTF is already a long document by any measure, and anything larger falls back
    /// to the plain-text pane, which reads it off the main thread like everything else.
    private static let richTextByteCap = 256 * 1024

    /// The last entry read for the preview, kept so reopening the same row costs nothing.
    ///
    /// Keyed by the record *and* the store's generation, so an entry rewritten in the
    /// editor is read again. Deliberately not keyed by the search terms: the highlighting
    /// is a layer drawn over this text rather than part of it, so typing must not throw
    /// away a document that was just read off disk. One entry, because the pointer is
    /// only ever on one row.
    private var previewCache: (id: UUID, generation: UInt64, load: ClipPreviewLoad)?

    /// Reads an entry's payload off the main thread: at most `previewCharacterCap`
    /// characters of its text, and its RTF where it has some.
    ///
    /// `@MainActor` for the cache above all — the store's state and this cache both
    /// belong to the main thread, and only the file read and the decode are handed to
    /// `previewQueue`.
    @MainActor
    func previewPayload(for record: ClipRecord) async -> ClipPreviewLoad {
        let generation = manager.store.generation
        if let cached = previewCache, cached.id == record.id, cached.generation == generation {
            return cached.load
        }

        let wantsText = record.kind != .image && !record.oversized
        let wantsRich = record.kind == .richText && !record.oversized
        guard wantsText || wantsRich else { return ClipPreviewLoad(text: nil, rich: nil) }

        // Only the file's location crosses over — none of the store's state is safe to
        // touch away from the main thread.
        let location = manager.store.payloadLocation(for: record.id)
        let isFiles = record.kind == .files
        let fallback = record.preview
        let cap = Self.richTextByteCap

        let load: ClipPreviewLoad = await withCheckedContinuation { continuation in
            Self.previewQueue.async {
                guard let data = try? Data(contentsOf: location),
                      let payload = ClipPayloadCoder.decode(data) else {
                    continuation.resume(returning: ClipPreviewLoad(text: nil, rich: nil))
                    return
                }
                var text: PreviewText?
                if wantsText {
                    let full: String
                    if isFiles {
                        full = ClipCapture.fileURLs(from: payload)
                            .map(\.path).joined(separator: "\n")
                    } else {
                        // Plain-text types only. The styled-text fallbacks in
                        // `plainText(from:)` go through NSAttributedString, whose HTML
                        // importer is main-thread-only and slow enough to stall the panel
                        // on its own; the stored preview line stands in for those.
                        full = ClipCapture.plainTextOnly(from: payload) ?? fallback
                    }
                    let capped = full.count > Self.previewCharacterCap
                    text = PreviewText(
                        body: capped ? String(full.prefix(Self.previewCharacterCap)) : full,
                        truncated: capped
                    )
                }
                var rich: Data?
                if wantsRich {
                    let rtf = payload
                        .compactMap { $0[NSPasteboard.PasteboardType.rtf.rawValue] }.first
                    rich = rtf.flatMap { $0.count <= cap ? $0 : nil }
                }
                continuation.resume(returning: ClipPreviewLoad(text: text, rich: rich))
            }
        }

        previewCache = (record.id, generation, load)
        return load
    }

    /// Hands an image entry to 预览.app.
    ///
    /// The payload is a plist on disk, not a file any other application can open, so the
    /// picture is written out to a temporary file first — in the background, because a
    /// full-resolution screenshot is megabytes and this runs from a click in the panel.
    /// The file is left for the system to collect: deleting it on a timer would race the
    /// application that is being asked to open it.
    func openImageExternally(_ record: ClipRecord) {
        guard record.kind == .image, !record.oversized else { return }
        let location = manager.store.payloadLocation(for: record.id)
        let stem = "hyper-preview-\(UUID().uuidString)"

        Self.previewQueue.async {
            guard let data = try? Data(contentsOf: location),
                  let payload = ClipPayloadCoder.decode(data)
            else { return }
            // The stored bytes, written out under the extension they actually are —
            // never re-encoded. Re-drawing through `NSImage` would mean AppKit drawing
            // off the main thread for no gain, and would hand 预览 a *copy* of the
            // picture rather than the original the row is holding.
            let candidates = [
                (NSPasteboard.PasteboardType.png.rawValue, "png"),
                (NSPasteboard.PasteboardType.tiff.rawValue, "tiff"),
            ]
            for (type, ext) in candidates {
                guard let bytes = payload.compactMap({ $0[type] }).first else { continue }
                let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("\(stem).\(ext)")
                guard (try? bytes.write(to: destination, options: .atomic)) != nil else { return }
                DispatchQueue.main.async { NSWorkspace.shared.open(destination) }
                return
            }
        }
    }

    func isQueued(_ id: UUID) -> Bool {
        queuedIDs.contains(id)
    }

    /// The number a row wears on the queue tab.
    ///
    /// Deliberately the row's own place in the list rather than its place in the whole
    /// queue: the same number is what ⌘n reaches, and with a query in the field a badge
    /// that disagreed with the shortcut beside it would be worse than one that counts
    /// only what is on screen.
    func queuePosition(at index: Int) -> Int? {
        filter == .queue ? index + 1 : nil
    }

    /// For the preview's per-format copy buttons. Routed through the manager so the
    /// write lands on the monitor's ignore list rather than in the history.
    func copyPlainString(_ string: String) {
        manager.copyPlainString(string)
    }
}

/// Borderless, non-activating, and still able to take key focus — the combination a
/// launcher-style panel needs. Without `canBecomeKey` a borderless window can never
/// receive typing; without `.nonactivatingPanel` showing it would yank the whole
/// application forward and complicate getting focus back to where the paste has to go.
final class ClipboardPanel: NSPanel {
    /// Cleared while a paste needs the keyboard to reach the target application. A
    /// window that is still allowed to become key simply takes it straight back.
    var acceptsKey = true

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// The preview sits in a window of its own so it can extend past the list's edge
/// instead of permanently eating half of it. It must never take focus, or it would
/// pull the keyboard away from the search field the moment it appeared.
final class ClipboardPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that acts on the click that reaches it.
///
/// The panel deliberately floats over an application that stays active, so *every*
/// click into it is a "first mouse" click — and AppKit's default is to spend that
/// click on bringing the window forward and discard it. `NSHostingView` inherits that
/// default, which is why an untouched panel ignores the first click on any row and
/// only the keyboard appears to work.
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class ClipboardPanelController {
    private unowned let manager: ClipboardManager
    private let model: ClipboardPanelModel

    private var panel: ClipboardPanel?
    private var previewPanel: ClipboardPreviewPanel?
    /// Where the preview goes, or nil when the screen has no room for it.
    private var previewFrame: NSRect?
    private var previewHideWork: DispatchWorkItem?
    /// Whether the panel is meant to be up. `panel.isVisible` cannot answer that: it
    /// stays true through the closing fade, so a `syncPreview` that arrives in those
    /// few frames would put the preview back and leave it stranded on screen after the
    /// list has gone.
    private var isOpen = false
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Modifiers carried by the most recent click into the panel.
    private var clickModifiers: NSEvent.ModifierFlags = []
    /// Set while a paste deliberately hands the keyboard to the target application and
    /// means to keep the panel up regardless.
    private var suppressResignHide = false
    /// Set for as long as a row is being dragged out of the panel — see
    /// `beginDragExemption()`.
    private var dragInFlight = false
    /// Whether the current exemption was started by a resign rather than by one of our
    /// own rows leaving. The two end differently — see `endDragExemption()`.
    private var exemptionIsIncoming = false
    /// The system's "reduce motion" setting as of the last `show()`. Read once per
    /// appearance rather than per animation: it is a system-wide preference that changes
    /// about never, and the panel's fade and its closing fade have to agree on it.
    private var motionReduced = false
    private var keyRestoreWork: DispatchWorkItem?
    /// Replays the exact operation that produced the visible failure. Kept by the
    /// controller rather than the model so view state stays value-only and testable.
    private var retryPasteAction: (() -> Void)?
    private var skipInvalidPasteAction: (() -> Void)?
    private var accessibilityPollTimer: Timer?
    /// Identifies the ordinary paste that currently owns the off-screen panel. It also
    /// prevents a second hotkey invocation from resetting that preserved state while the
    /// manager is still activating the target application.
    private var closingPasteToken: UUID?

    private let editor = ClipEditorController()

    /// Whoever was in front when the panel opened — the application a paste has to go
    /// back to. Captured before the panel appears, because afterwards it is too late.
    private var previousApp: NSRunningApplication?

    init(manager: ClipboardManager) {
        self.manager = manager
        self.model = ClipboardPanelModel(manager: manager)

        // The preview follows the selection, which anything from a keystroke to a
        // hover to a history change can move. Rather than remember to poke it from
        // each of those, it re-derives itself whenever the model reports a change.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncPreview() }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Show / hide

    /// `rememberingPreviousApp` is for the paths that reopen the panel after our own
    /// windows were in front — the editor, above all. Whoever was frontmost *then* is
    /// Hyper itself, and a paste that activated Hyper would go nowhere.
    func show(rememberingPreviousApp app: NSRunningApplication? = nil) {
        // An edit in progress owns the screen. The list would appear over a window the
        // user is typing into, take the keyboard from it, and — being non-activating —
        // hand it back the moment anything else was clicked. The editor comes forward
        // instead; the list is one keystroke away again as soon as the edit is done.
        guard !editor.isVisible else {
            editor.bringToFront()
            return
        }
        guard closingPasteToken == nil else { return }

        previousApp = app ?? NSWorkspace.shared.frontmostApplication
        isOpen = true

        motionReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let panel = existingPanel()
        model.reduceMotion = motionReduced
        // Read fresh on every appearance rather than observed: the panel opens often and
        // lives briefly, so the moment it comes up is late enough for any setting changed
        // while it was away.
        model.returnPastes = manager.settings.returnActionMode == .paste
        model.panelWillShow()
        // After `panelWillShow`, which resets everything the last appearance left behind.
        publishPasteTarget()
        position(panel)

        panel.alphaValue = motionReduced ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if !motionReduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.11
                panel.animator().alphaValue = 1
            }
            growIn(panel)
        }

        installKeyMonitor()
        observeResign(panel)
        syncPreview()
    }

    /// Tells the list which application ↩ will paste into.
    ///
    /// Hyper itself is filtered out rather than shown: the paths that reopen the panel
    /// over our own windows carry the *original* target forward, and the ones that do
    /// not have nowhere useful to paste anyway — a badge naming Hyper would be pointing
    /// at the panel the user is looking at.
    private func publishPasteTarget() {
        guard let app = previousApp,
              app.processIdentifier != NSRunningApplication.current.processIdentifier,
              let name = app.localizedName, !name.isEmpty
        else {
            model.setPasteTarget(name: nil, icon: nil)
            return
        }
        model.setPasteTarget(name: name, icon: app.icon)
    }

    /// The barely-there swell under the fade: 0.98 to 1.
    ///
    /// On the content view's layer rather than on the window, because a window cannot be
    /// scaled — animating its frame instead would fight `position(_:)` for the same
    /// rectangle and move the list out from under the pointer. Added as an animation
    /// with no model change behind it, so it lands on the identity transform by itself
    /// and leaves nothing to undo. The cost of the shortcut is that the window's shadow,
    /// which the window server draws from the frame, does not scale with the content for
    /// the tenth of a second this lasts — invisible at 2% under a fade from nothing.
    private func growIn(_ panel: NSPanel) {
        guard let layer = panel.contentView?.layer else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.98
        scale.toValue = 1.0
        scale.duration = 0.13
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "hyper.panelGrowIn")
    }

    /// `animated: false` takes the panel off screen synchronously.
    ///
    /// That matters for anything that follows the hide with a synthetic keystroke. A
    /// non-activating panel does not activate the application, but while it is on
    /// screen it *does* hold the system keyboard focus — that is the whole point of
    /// the style. A ⌘V posted during the fade is therefore delivered to the panel's
    /// own search field, never to the target application, and nothing downstream can
    /// detect it: `NSWorkspace.frontmostApplication` names the target throughout,
    /// because a non-activating panel never changed it in the first place.
    func hide(animated: Bool = true) {
        isOpen = false
        closingPasteToken = nil
        retryPasteAction = nil
        skipInvalidPasteAction = nil
        stopAccessibilityPolling()
        keyRestoreWork?.cancel()
        keyRestoreWork = nil
        suppressResignHide = false
        dragInFlight = false
        exemptionIsIncoming = false
        clickModifiers = []
        panel?.acceptsKey = true
        model.panelDidHide()
        removeKeyMonitor()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        // Straight out, never faded: a preview lingering beside a panel that is already
        // gone reads as a stray window rather than as part of the same thing.
        previewHideWork?.cancel()
        previewHideWork = nil
        previewPanel?.orderOut(nil)
        guard let panel, panel.isVisible else { return }
        // "Reduce motion" takes the same path a paste does: straight off screen.
        guard animated, !motionReduced else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        }
    }

    private func existingPanel() -> ClipboardPanel {
        if let panel { return panel }

        let panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        decorate(panel)
        // Dragging the list would leave the preview behind, and a launcher that is
        // dismissed on the next click has nothing to gain from being movable.
        panel.isMovableByWindowBackground = false
        panel.contentView = chrome(ClipboardPanelView(model: model, actions: makeActions()))
        self.panel = panel
        return panel
    }

    private func existingPreviewPanel() -> ClipboardPreviewPanel {
        if let previewPanel { return previewPanel }

        let panel = ClipboardPreviewPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        decorate(panel)
        // Left interactive on purpose: a long entry's preview scrolls, and its text is
        // selectable. Clicking it cannot dismiss the list, because this panel never
        // becomes key and so the list never resigns.
        panel.contentView = chrome(ClipboardPreviewView(model: model))
        previewPanel = panel
        return panel
    }

    private func decorate(_ panel: NSPanel) {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// The blurred, rounded backdrop both windows share, wrapped around a SwiftUI root.
    private func chrome<Content: View>(_ content: Content) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        let hosting = PanelHostingView(rootView: content)
        // Without this the hosting view publishes SwiftUI's fitting size as its
        // intrinsic size, and because it is pinned to the content view those become
        // required constraints on the window: a long history then stretches the panel
        // to the height of the whole list instead of scrolling inside it. The windows
        // size themselves in `position(_:)`; the content has to live within that.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// Sizes are fixed per appearance rather than content-driven: a launcher that changes
    /// shape as you type is hard to aim at, and one row of history should not produce a
    /// different window than a thousand. Which of the three it is comes from the settings
    /// and is read on the way up, so changing it takes effect at the next opening without
    /// anything having to observe it. Only a screen too small to hold it shrinks it.
    /// Both windows are the same shape — the preview reads as the list's other half
    /// rather than as a different kind of thing.
    private var windowSize: NSSize {
        let dimensions = manager.settings.panelDimensions
        return NSSize(width: dimensions.width, height: dimensions.height)
    }

    private static let windowGap: CGFloat = 10
    /// How close to the screen's edges either window may be placed.
    private static let screenMargin: CGFloat = 12

    /// The narrowest the preview may be squeezed to rather than not appear at all.
    ///
    /// Matching the list's width is what makes the pair read as two halves of one thing,
    /// but insisting on it meant the 「宽大」 panel had no preview at all on a 1440pt
    /// display — 480 + 10 + 480 + margins does not fit, so `→` and every hover silently
    /// did nothing while the hint bar went on advertising them. 280pt still holds forty
    /// characters a line, which is enough to read an entry by.
    private static let minPreviewWidth: CGFloat = 280

    /// Opens on whichever screen the pointer is on — a menu bar panel that appeared on
    /// the laptop display while you were working on the external one would be worse than
    /// useless — and where on that screen the settings say.
    ///
    /// Only the list is placed. The preview is the exception rather than the rule now
    /// that it takes a hover to summon, so placing the pair as one would leave the list
    /// permanently off to one side for the sake of a window that is usually absent.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let wanted = windowSize
        let size = NSSize(
            width: min(wanted.width, visible.width - 40),
            height: min(wanted.height, visible.height - 40)
        )
        let origin = origin(for: size, in: visible)
        let x = origin.x
        let y = origin.y
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        // To the right by preference, to the left if that is where the room is — at the
        // list's own width where it fits, and squeezed down to `minPreviewWidth` where it
        // does not. Only a side with room for neither is given up on.
        let toRight = x + size.width + Self.windowGap
        let leftEdge = x - Self.windowGap
        let rightRoom = (visible.maxX - Self.screenMargin) - toRight
        let leftRoom = leftEdge - (visible.minX + Self.screenMargin)

        func rightFrame(_ width: CGFloat) -> NSRect {
            NSRect(x: toRight, y: y, width: width, height: size.height)
        }
        func leftFrame(_ width: CGFloat) -> NSRect {
            NSRect(x: leftEdge - width, y: y, width: width, height: size.height)
        }

        if rightRoom >= size.width {
            previewFrame = rightFrame(size.width)
        } else if leftRoom >= size.width {
            previewFrame = leftFrame(size.width)
        } else if rightRoom >= Self.minPreviewWidth {
            previewFrame = rightFrame(rightRoom.rounded(.down))
        } else if leftRoom >= Self.minPreviewWidth {
            previewFrame = leftFrame(leftRoom.rounded(.down))
        } else {
            previewFrame = nil
        }
        // So the hint bar and the shortcut sheet can stop offering a key that has nowhere
        // to put its window.
        model.previewAvailable = previewFrame != nil
    }

    /// Where the list's bottom-left corner goes, in the screen coordinates AppKit uses —
    /// y counts up from the bottom.
    private func origin(for size: NSSize, in visible: NSRect) -> NSPoint {
        switch manager.settings.panelPositionMode {
        case .center:
            // A little above centre, so the list sits where the eye already is rather
            // than at the very middle.
            return NSPoint(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.midY - size.height / 2 + visible.height * 0.08).rounded()
            )
        case .mouse:
            // The pointer marks the top edge, centred on it, and the panel hangs below —
            // which is where a menu opened from a click goes, and it keeps the pointer
            // off the list. Landing it *on* a row would hover that row on the first
            // frame, which is the one thing `hoverArmed` exists to prevent.
            let pointer = NSEvent.mouseLocation
            let margin = Self.screenMargin
            let x = min(
                max(pointer.x - size.width / 2, visible.minX + margin),
                visible.maxX - size.width - margin
            )
            let y = min(
                max(pointer.y - size.height - 8, visible.minY + margin),
                visible.maxY - size.height - margin
            )
            return NSPoint(x: x.rounded(), y: y.rounded())
        case .bottom:
            return NSPoint(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.minY + 24).rounded()
            )
        }
    }

    /// Brings the preview up while the pointer is on either window, and takes it away
    /// shortly after the pointer leaves both.
    private func syncPreview() {
        let wanted = isOpen && model.previewOpen
            && model.previewRecord != nil && previewFrame != nil

        guard wanted else {
            // Closing is deferred: reaching for the preview means crossing the gap
            // between the windows, and for those few frames the pointer is on neither.
            guard previewPanel?.isVisible == true, previewHideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.previewHideWork = nil
                guard let self, !(self.isOpen && self.model.previewOpen) else { return }
                self.previewPanel?.orderOut(nil)
            }
            previewHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            return
        }

        previewHideWork?.cancel()
        previewHideWork = nil

        guard let panel, let previewFrame else { return }
        let preview = existingPreviewPanel()
        guard !preview.isVisible else { return }
        preview.setFrame(previewFrame, display: false)
        preview.alphaValue = motionReduced ? 1 : 0
        preview.orderFrontRegardless()
        if !motionReduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                preview.animator().alphaValue = 1
            }
        }
        // Ordering the preview up must not cost the list its keyboard focus.
        panel.makeKeyAndOrderFront(nil)
    }

    private func observeResign(_ panel: NSPanel) {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // Clicking anywhere else means the user is done with the panel — unless the
            // panel itself just handed the keyboard over so a paste could land, or a row
            // is on its way out under the pointer.
            guard let self, !self.suppressResignHide, !self.dragInFlight else { return }
            // A resign that arrives with the button still down is not a click that is
            // over: it is the *start* of something, and what it usually starts is a drag.
            // That is the whole reason dragging a file into the list was impossible —
            // picking it up in Finder activates Finder, the panel resigns, and the list is
            // gone long before the pointer arrives with anything in it. So the panel waits
            // for the release and then decides the way a drag *out* does: still over the
            // panel, it stays; let go anywhere else, the user is done with it. The cost is
            // that an ordinary click elsewhere now dismisses on mouse-up rather than
            // mouse-down, which is a frame or two nobody can see.
            guard NSEvent.pressedMouseButtons & 1 == 0 else {
                self.beginDragExemption(incoming: true)
                return
            }
            self.hide()
        }
    }

    // MARK: - Actions

    private func makeActions() -> ClipboardPanelActions {
        ClipboardPanelActions(
            paste: { [weak self] plainText in self?.paste(plainTextOnly: plainText) },
            pasteKeepingOpen: { [weak self] in self?.paste(plainTextOnly: false, keepingPanelOpen: true) },
            pasteTransformed: { [weak self] transform in
                self?.paste(plainTextOnly: true, transform: transform)
            },
            copyOnly: { [weak self] in self?.copyOnly() },
            // Whatever ↩ currently means — see `performReturnAction()`.
            returnAction: { [weak self] in self?.performReturnAction() },
            // Through the same guard ⌥↩ goes through, so the batch bar's button and the
            // key it advertises cannot mean two different things on the queue tab.
            enqueue: { [weak self] in self?.enqueueSelected() },
            delete: { [weak self] in self?.deleteSelected() },
            dequeue: { [weak self] in self?.dequeueSelected() },
            togglePin: { [weak self] in self?.togglePin() },
            clearQueue: { [weak self] in
                self?.manager.clearQueue()
                ClipboardHUD.shared.show("队列已清空", symbol: "trash")
            },
            removeFromQueue: { [weak self] id in self?.manager.removeFromQueue(id) },
            moveInQueue: { [weak self] id, up in self?.manager.moveInQueue(id, up: up) },
            toggleShortcuts: { [weak self] in
                guard let self else { return }
                // The first-run card and the shortcut sheet share one layer and the card
                // wins it, so toggling the sheet from under the card would flip something
                // nobody can see — and the hint bar's `?` sits below the overlay, where it
                // is perfectly clickable while the card is up. The card goes first, which
                // is also what the `?` key does.
                self.model.dismissOnboarding()
                self.model.showingShortcuts.toggle()
            },
            toggleChecked: { [weak self] id in self?.model.toggleChecked(id) },
            togglePinRow: { [weak self] index in self?.act(onRow: index) { $0.togglePin($1.id) } },
            deleteRow: { [weak self] index in self?.act(onRow: index) { $0.delete($1.id) } },
            dequeueRow: { [weak self] index in self?.dequeueRow(index) },
            selectIndex: { [weak self] index in self?.model.select(index) },
            activateRow: { [weak self] index in self?.activateRow(index) },
            hoverIndex: { [weak self] index in self?.model.hover(index) },
            hoverEnded: { [weak self] index in self?.model.hoverEnded(index) },
            edit: { [weak self] in self?.editSelected() },
            dragBegan: { [weak self] record in
                guard let self else { return NSItemProvider() }
                self.beginDragExemption()
                self.model.beginRowDrag(record.id)
                // On 收藏 with an empty field a row drag *is* the reorder: every row the
                // pointer crosses rewrites the band's order on the way past. Carrying the
                // row's content as well would mean a drag aimed at another application
                // could be accepted there — and the reorder it left strewn behind it,
                // already written to disk, was never asked for. So that page hands over a
                // provider no other application can read.
                guard !self.model.canReorderPinned else {
                    return self.reorderProvider(for: record)
                }
                return ClipDragItem.provider(for: record, store: self.manager.store)
            },
            movePinnedRow: { [weak self] destination in self?.movePinnedRow(to: destination) },
            reorderPinned: { [weak self] index, up in self?.reorderPinned(index, up: up) },
            saveDropped: { [weak self] providers in self?.saveDropped(providers) },
            dismissOnboarding: { [weak self] in self?.model.dismissOnboarding() },
            retryPaste: { [weak self] in self?.retryPaste() },
            skipInvalidPaste: { [weak self] in self?.skipInvalidPaste() },
            openAccessibilitySettings: { [weak self] in
                self?.openAccessibilitySettings()
            },
            dismissPasteIssue: { [weak self] in
                self?.retryPasteAction = nil
                self?.skipInvalidPasteAction = nil
                self?.stopAccessibilityPolling()
                self?.suppressResignHide = false
                self?.model.dismissPasteIssue()
            },
            close: { [weak self] in self?.hide() }
        )
    }

    /// The row buttons' way in: act on the row that was clicked, and on nothing else.
    ///
    /// Deliberately not through `actionTargets`, which the keys and the batch bar go
    /// through: with rows ticked, that would answer a click on one row's trash with the
    /// deletion of a dozen others. The selection still follows the click, because a
    /// button that acted somewhere other than where the highlight then sits would leave
    /// the panel describing a row it did not touch.
    private func act(onRow index: Int, _ body: (ClipboardManager, ClipRecord) -> Void) {
        guard model.results.indices.contains(index) else { return }
        model.select(index)
        body(manager, model.results[index])
    }

    // MARK: - Dragging out

    /// What a row on the 收藏 tab drags: nothing anyone else can take.
    ///
    /// Both representations are `.ownProcess`, so the drag is legible inside this
    /// application and empty outside it — every other application refuses it, and the
    /// reorder can only ever end where it started. The text is registered because the
    /// list's own drop targets are declared over `ClipDropIntake.acceptedTypes` and would
    /// not otherwise see the drag at all; the private identifier is the same marker
    /// `ClipDragItem` puts on every row that leaves the list, which is how the drop
    /// targets tell a row of ours from something dragged in.
    private func reorderProvider(for record: ClipRecord) -> NSItemProvider {
        let provider = NSItemProvider()
        let preview = record.preview
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .ownProcess
        ) { completion in
            completion(Data(preview.utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: ClipDragItem.privateTypeIdentifier, visibility: .ownProcess
        ) { completion in
            completion(Data(record.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// A drag out of the panel takes the keyboard with it: the window it passes over
    /// becomes key, and `didResignKey` would tear the list down mid-drag. So the hide is
    /// suspended for the duration.
    ///
    /// There is no completion to hang that on. SwiftUI's `.onDrag` hands back an item
    /// provider and never says another word, and the drag runs its own event loop, so a
    /// mouse-up monitor is not reliably delivered either. `NSEvent.pressedMouseButtons` is
    /// a global query that owes nothing to focus or to the event stream, which makes
    /// polling it the one account of "the button came back up" that cannot be starved.
    ///
    /// `incoming` marks the exemption a *resign* started rather than one of our own rows
    /// leaving: the button went down somewhere else entirely. That is sometimes a file on
    /// its way here, but just as often a selection being dragged through another
    /// application's text — which has nothing to do with the panel and must not keep it
    /// pinned over everything else for half a minute. So that path is held to ten seconds
    /// and has to show something for itself when it ends; see `endDragExemption`.
    private func beginDragExemption(incoming: Bool = false) {
        guard !dragInFlight else { return }
        dragInFlight = true
        exemptionIsIncoming = incoming
        model.clearDropCompleted()

        var ticks = 0
        // 0.06s a tick: half a minute for a drag this panel started, ten seconds for one
        // it only overheard.
        let cap = incoming ? 166 : 500
        func poll() {
            guard self.dragInFlight else { return }
            ticks += 1
            // Capped, so a drag whose release is somehow never observed costs a bounded
            // wait rather than a panel that can no longer be dismissed.
            guard NSEvent.pressedMouseButtons & 1 == 0 || ticks > cap else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: poll)
                return
            }
            // The button comes up before the drag session finishes concluding, and the
            // drop it delivers is what an incoming exemption is judged on. Deciding in the
            // same instant the button is seen up would sometimes read "nothing arrived"
            // for a file that was about to. A beat costs nothing here: this path already
            // ends on mouse-up rather than mouse-down.
            guard incoming else {
                self.endDragExemption()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.endDragExemption() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: poll)
    }

    /// Where the pointer let go decides what the panel does next.
    ///
    /// Back inside the panel means the drag was abandoned, so the list takes its keyboard
    /// back and stays. Anywhere else the content has been delivered and the panel has done
    /// its job — and it has to be told so explicitly, because it stopped being the key
    /// window while the hide was suspended and no second `didResignKey` is coming.
    ///
    /// An `incoming` exemption is judged more harshly. It was started by a mouse-down we
    /// never saw the beginning of, so "the pointer ended up over the panel" proves nothing
    /// — a text selection dragged past the list ends exactly like that, and taking the
    /// keyboard back there would steal it from whatever the user is actually working in.
    /// It has to have delivered something: a drop the list took, or a drag of our own that
    /// began while it was running. Otherwise the resign stands and the panel goes.
    private func endDragExemption() {
        guard dragInFlight else { return }
        dragInFlight = false
        let incoming = exemptionIsIncoming
        exemptionIsIncoming = false
        let delivered = model.dropCompletedDuringExemption
        let ownDrag = model.draggingID != nil
        model.clearDropCompleted()
        model.endRowDrag()
        guard isOpen, let panel else { return }

        let pointer = NSEvent.mouseLocation
        let overPanel = panel.frame.contains(pointer)
        let overPreview = previewPanel?.isVisible == true
            && previewPanel?.frame.contains(pointer) == true
        if incoming, !delivered, !(ownDrag && (overPanel || overPreview)) {
            hide()
            return
        }
        if overPanel || overPreview {
            panel.makeKeyAndOrderFront(nil)
        } else {
            hide()
        }
    }

    // MARK: - Dragging in

    /// The live half of the 收藏 reorder: the row in flight takes the place of the row the
    /// pointer has just crossed onto, and the whole band's ranks are rewritten with it.
    ///
    /// Called on every crossing rather than once when the button comes up, which is what
    /// makes the list rearrange under the pointer instead of jumping when it is released.
    /// The guard is what keeps that honest — the list is only the band itself on the 收藏
    /// tab with an empty field, and anywhere else these indices would mean nothing.
    private func movePinnedRow(to destination: Int) {
        guard model.canReorderPinned, let source = model.draggingIndex,
              source != destination, model.results.indices.contains(destination)
        else { return }
        manager.movePinned(from: source, to: destination)
    }

    /// The 收藏 tab's 上移 / 下移: the same move a drag makes, one step at a time, for
    /// anyone not driving the panel with a pointer — and the only way VoiceOver has of
    /// making it at all, since a drag is not something it can perform.
    private func reorderPinned(_ index: Int, up: Bool) {
        guard model.canReorderPinned, model.results.indices.contains(index) else { return }
        let destination = up ? index - 1 : index + 1
        guard model.results.indices.contains(destination) else { return }
        manager.movePinned(from: index, to: destination)
    }

    /// Something was dragged in from another application. Reading it is asynchronous, so
    /// the row appears a beat after the pointer lets go — which is also when the HUD says
    /// it did.
    private func saveDropped(_ providers: [NSItemProvider]) {
        ClipDropIntake.read(providers) { [weak self] payload, kind in
            self?.manager.saveDropped(payload: payload, kind: kind)
        }
    }

    // MARK: - Editing

    /// Opens the editor on the selected entry.
    ///
    /// The panel goes away first rather than staying up behind it. The editor has to be a
    /// real key window to be typed into, which means activating Hyper, which means the
    /// list would resign and hide anyway — and two overlapping windows for one edit is a
    /// worse picture than one. What happens afterwards depends on the button: "保存并粘贴"
    /// goes straight down the paste path and never brings the list back, because pasting
    /// is what closing the panel would have led to anyway; "仅保存" and "取消" reopen it,
    /// with the original target application remembered across the round trip.
    private func editSelected() {
        guard let record = model.selected, !record.oversized,
              record.kind == .text || record.kind == .url
        else { return }

        let id = record.id
        let app = previousApp
        // Read while the store is still the only thing that has been touched — after the
        // hide, the payload is exactly as it was, but this keeps the two in one place.
        let text = manager.store.payload(for: id)
            .flatMap(ClipCapture.plainText) ?? record.preview

        hide(animated: false)

        editor.show(text: text) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancelled:
                self.reopen(restoring: app)
            case .saved(let newText, false):
                self.manager.updateText(id: id, newText: newText)
                self.reopen(restoring: app)
            case .saved(let newText, true):
                guard let updated = self.manager.updateText(id: id, newText: newText) else {
                    self.reopen(restoring: app)
                    return
                }
                // Hyper is the active application at this point — the editor made it so.
                // Hand the front back before the keystroke goes out.
                NSApp.deactivate()
                app?.activate(options: [])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.manager.paste(
                        records: [updated], merged: false, plainTextOnly: false, activating: app
                    )
                }
            }
        }
    }

    /// Puts the list back after the editor, with focus where it was before.
    private func reopen(restoring app: NSRunningApplication?) {
        NSApp.deactivate()
        app?.activate(options: [])
        // A beat for the activation to land: the panel is non-activating, so it has to
        // arrive over an application that is already frontmost or it will look as though
        // Hyper itself is in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.show(rememberingPreviousApp: app)
        }
    }

    /// A click landed on a row. What it does depends on the modifiers held at the time:
    /// ⌘ pastes and leaves the panel up so the next one can follow, ⌥ ticks the row for
    /// a merged paste, and a plain click pastes and closes.
    private func activateRow(_ index: Int) {
        model.select(index)
        let flags = modifiersHeld()
        // Consumed, so a click whose flags never arrived cannot inherit the last one's.
        // Falling back to "no modifiers" costs at most a panel that closes when it could
        // have stayed; inheriting a stale ⌘ would leave it open when it should close.
        clickModifiers = []
        if flags.contains(.command) {
            paste(plainTextOnly: false, keepingPanelOpen: true)
        } else if flags.contains(.option) {
            guard model.results.indices.contains(index) else { return }
            model.toggleChecked(model.results[index].id)
        } else {
            // A plain click is the pointer's ↩, so it means whatever ↩ means. ⌘-click and
            // ⌥-click are unaffected: they name what they do rather than deferring to a
            // default, and there is nothing for the setting to swap them with.
            performReturnAction()
        }
    }

    /// The modifiers on the click currently being handled.
    ///
    /// Deliberately not `NSEvent.modifierFlags`. While the panel is up the application
    /// is active but *not* frontmost — the menu bar still belongs to the application
    /// behind — so the window server delivers modifier-key events there and they never
    /// reach us, leaving that global permanently stale. That is why ⌘ appeared to go to
    /// the application behind the panel.
    ///
    /// Not `CGEventSource.flagsState` either, tempting as a focus-independent read is:
    /// `Paster.sendPaste` synthesizes ⌘V without a matching modifier release, so the
    /// session state latches "command held" afterwards and every later plain click
    /// reads as a ⌘-click. The event's own flags are stamped by the window server when
    /// the click happens, owe nothing to focus, and cannot be poisoned that way.
    private func modifiersHeld() -> NSEvent.ModifierFlags { clickModifiers }

    private func paste(
        plainTextOnly: Bool, keepingPanelOpen: Bool = false, transform: PasteTransform? = nil
    ) {
        guard !keepingPanelOpen else {
            pasteKeepingPanelOpen(plainTextOnly: plainTextOnly, transform: transform)
            return
        }
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        beginClosingPaste(
            targets: targets, plainTextOnly: plainTextOnly, transform: transform,
            activating: previousApp
        )
    }

    /// Hands the keyboard back without throwing the panel state away. The window still
    /// disappears synchronously, exactly as the successful path always has, but the
    /// model, query, selection, monitors and target application remain available until
    /// the manager reports whether the transaction crossed its honest success boundary.
    private func beginClosingPaste(
        targets: [ClipRecord], plainTextOnly: Bool, transform: PasteTransform?,
        activating app: NSRunningApplication?,
        batchPolicy: ClipboardBatchPolicy = .allOrNothing
    ) {
        guard !targets.isEmpty, let panel else { return }
        stopAccessibilityPolling()
        model.dismissPasteIssue()
        retryPasteAction = nil
        skipInvalidPasteAction = nil
        keyRestoreWork?.cancel()
        keyRestoreWork = nil
        suppressResignHide = true
        panel.acceptsKey = false
        previewHideWork?.cancel()
        previewHideWork = nil
        previewPanel?.orderOut(nil)
        // This is intentionally not `hide()`: a rejected transaction must be able to
        // restore this exact query and multi-selection instead of opening a reset panel.
        panel.orderOut(nil)
        let token = UUID()
        closingPasteToken = token

        let merged = targets.count > 1
        // The same hand-off beat as before. Removing it would change which application
        // receives a fast paste even though the transaction plumbing itself is sound.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            self.manager.paste(
                records: targets, merged: merged, plainTextOnly: plainTextOnly,
                activating: app, transform: transform, batchPolicy: batchPolicy
            ) { [weak self] result in
                guard let self else { return }
                guard self.closingPasteToken == token else { return }
                self.closingPasteToken = nil
                if result.succeeded {
                    self.model.clearChecked()
                    // The window is already off-screen, so this only commits lifecycle
                    // cleanup. No fade or extra activation is introduced on success.
                    self.hide(animated: false)
                } else {
                    self.restorePanel(
                        after: result,
                        retry: { [weak self] in
                            self?.beginClosingPaste(
                                targets: targets, plainTextOnly: plainTextOnly,
                                transform: transform, activating: app,
                                batchPolicy: batchPolicy
                            )
                        },
                        skipInvalid: { [weak self] in
                            self?.beginClosingPaste(
                                targets: targets, plainTextOnly: plainTextOnly,
                                transform: transform, activating: app,
                                batchPolicy: .skipInvalid
                            )
                        }
                    )
                }
            }
        }
    }

    /// Pastes and leaves the panel where it is, so several entries can be sent one after
    /// another without reopening it.
    ///
    /// The hard part is that the panel has to genuinely hand the keyboard over first.
    /// The ordinary paste gets that for free by taking the panel off screen; this one
    /// cannot, so it asks and then *waits to be sure*. Asking alone is not enough:
    ///
    ///   * `withApplicationFrontmost` is no help here. It waits on
    ///     `NSWorkspace.frontmostApplication`, which names the target application the
    ///     entire time the panel holds the keyboard — so it sees nothing to wait for and
    ///     fires the keystroke almost immediately.
    ///   * A panel that may still become key takes the focus straight back, which is why
    ///     `acceptsKey` is cleared for the duration.
    ///
    /// Send the ⌘V too early and it lands on the panel instead, where nothing handles it
    /// — that is the beep, and the paste that never arrives.
    private func pasteKeepingPanelOpen(plainTextOnly: Bool, transform: PasteTransform? = nil) {
        let targets = model.actionTargets
        guard !targets.isEmpty, let panel else { return }
        beginKeepingOpenPaste(
            targets: targets, plainTextOnly: plainTextOnly, transform: transform,
            activating: previousApp, panel: panel
        )
    }

    private func beginKeepingOpenPaste(
        targets: [ClipRecord], plainTextOnly: Bool, transform: PasteTransform?,
        activating app: NSRunningApplication?, panel: ClipboardPanel,
        batchPolicy: ClipboardBatchPolicy = .allOrNothing
    ) {
        let merged = targets.count > 1
        stopAccessibilityPolling()
        model.dismissPasteIssue()
        retryPasteAction = nil
        skipInvalidPasteAction = nil

        keyRestoreWork?.cancel()
        keyRestoreWork = nil
        suppressResignHide = true

        panel.acceptsKey = false
        NSApp.deactivate()
        app?.activate(options: [])

        whenKeyboardReleased { [weak self] released in
            guard let self else { return }
            // If it never let go, fall back to what always works: off screen for the
            // keystroke, and straight back afterwards.
            if !released { panel.orderOut(nil) }
            self.manager.paste(
                records: targets, merged: merged, plainTextOnly: plainTextOnly,
                activating: app, transform: transform, batchPolicy: batchPolicy
            ) { [weak self] result in
                guard let self else { return }
                if result.succeeded {
                    self.model.clearChecked()
                    self.retryPasteAction = nil
                    self.model.dismissPasteIssue()
                } else {
                    self.presentPasteIssue(
                        result,
                        retry: { [weak self, weak panel] in
                            guard let self, let panel else { return }
                            self.beginKeepingOpenPaste(
                                targets: targets, plainTextOnly: plainTextOnly,
                                transform: transform, activating: app, panel: panel,
                                batchPolicy: batchPolicy
                            )
                        },
                        skipInvalid: { [weak self, weak panel] in
                            guard let self, let panel else { return }
                            self.beginKeepingOpenPaste(
                                targets: targets, plainTextOnly: plainTextOnly,
                                transform: transform, activating: app, panel: panel,
                                batchPolicy: .skipInvalid
                            )
                        }
                    )
                }
                self.scheduleKeyRestore(reshowing: !released)
            }
        }
    }

    /// Polls briefly for the panel to stop being the key window. Focus changes are
    /// asynchronous, and the one notification that would report this — `didResignKey` —
    /// is exactly what this path suppresses.
    private func whenKeyboardReleased(_ body: @escaping (Bool) -> Void) {
        var attempts = 0
        func check() {
            guard let panel else { return body(false) }
            if !panel.isKeyWindow { return body(true) }
            attempts += 1
            guard attempts < 15 else { return body(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
        }
        check()
    }

    /// Takes the keyboard back once the paste has landed, so Escape and the search field
    /// work again — and so clicking away closes the panel as it should.
    private func scheduleKeyRestore(reshowing: Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.keyRestoreWork = nil
            self.suppressResignHide = false
            guard self.isOpen, let panel = self.panel else { return }
            panel.acceptsKey = true
            if reshowing { panel.orderFrontRegardless() }
            panel.makeKeyAndOrderFront(nil)
        }
        keyRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Restores an ordinary paste that temporarily took the panel off screen. No model
    /// reset occurs, so query text, highlighted row and checked rows remain exactly as
    /// they were when the operation began.
    private func restorePanel(
        after result: ClipboardOperationResult, retry: @escaping () -> Void,
        skipInvalid: @escaping () -> Void
    ) {
        presentPasteIssue(result, retry: retry, skipInvalid: skipInvalid)
        guard isOpen, let panel else { return }
        panel.acceptsKey = true
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        syncPreview()
        // `orderOut` posts resign asynchronously. Keep the exemption through the next
        // main turn so that stale notification cannot immediately hide the repaired UI.
        DispatchQueue.main.async { [weak self] in self?.suppressResignHide = false }
    }

    private func presentPasteIssue(
        _ result: ClipboardOperationResult, retry: @escaping () -> Void,
        skipInvalid: (() -> Void)? = nil
    ) {
        retryPasteAction = retry
        skipInvalidPasteAction = skipInvalid
        model.presentPasteIssue(result)
    }

    private func retryPaste() {
        guard let retry = retryPasteAction else { return }
        // The closure installs itself again only if the retry also fails. Clearing first
        // prevents a double activation from replaying an operation already in flight.
        retryPasteAction = nil
        skipInvalidPasteAction = nil
        model.dismissPasteIssue()
        retry()
    }

    private func skipInvalidPaste() {
        guard model.pasteIssue?.offersSkipInvalid == true,
              let skip = skipInvalidPasteAction else { return }
        retryPasteAction = nil
        skipInvalidPasteAction = nil
        model.dismissPasteIssue()
        skip()
    }

    /// Keeps the failed transaction available while System Settings is in front and
    /// notices the grant without requiring an app restart or a fresh panel invocation.
    private func openAccessibilitySettings() {
        stopAccessibilityPolling()
        suppressResignHide = true
        Permissions.requestTrust()
        Permissions.openAccessibilitySettings()

        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard Permissions.accessibilityStatus() == .granted else { return }
            self.stopAccessibilityPolling()
            self.model.noteAccessibilityPermissionGranted()
            guard self.isOpen, let panel = self.panel else { return }
            panel.acceptsKey = true
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in self?.suppressResignHide = false }
        }
        accessibilityPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
    }

    private func copyOnly() {
        guard let record = model.selected else { return }
        copy(record: record)
    }

    private func copy(record: ClipRecord) {
        stopAccessibilityPolling()
        model.dismissPasteIssue()
        retryPasteAction = nil
        skipInvalidPasteAction = nil
        let result = manager.copyToClipboard(record, plainTextOnly: false)
        if result.succeeded {
            hide()
        } else {
            presentPasteIssue(result) { [weak self] in self?.copy(record: record) }
        }
    }

    /// Whether ↩ pastes or only copies, as the settings have it. Read at the moment the
    /// key is pressed rather than cached, so a change made while the panel is up takes
    /// effect on the very next Return.
    private var returnPastes: Bool { manager.settings.returnActionMode == .paste }

    /// ↩ under 「仅复制并关闭面板」. The same targets the paste would have taken, put on
    /// the clipboard instead of sent — including the merge, which is the whole of what a
    /// multi-row paste does before the keystroke.
    private func copySelected() {
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        copy(targets: targets)
    }

    private func copy(
        targets: [ClipRecord], batchPolicy: ClipboardBatchPolicy = .allOrNothing
    ) {
        stopAccessibilityPolling()
        model.dismissPasteIssue()
        retryPasteAction = nil
        skipInvalidPasteAction = nil
        let result = targets.count > 1
            ? manager.copyMerged(targets, batchPolicy: batchPolicy)
            : manager.copyToClipboard(targets[0], plainTextOnly: false)
        if result.succeeded {
            model.clearChecked()
            hide()
        } else {
            presentPasteIssue(
                result,
                retry: { [weak self] in
                    self?.copy(targets: targets, batchPolicy: batchPolicy)
                },
                skipInvalid: { [weak self] in
                    self?.copy(targets: targets, batchPolicy: .skipInvalid)
                }
            )
        }
    }

    /// What ↩ and a plain click do, whichever way round the setting has them.
    private func performReturnAction() {
        if returnPastes {
            paste(plainTextOnly: false)
        } else {
            copySelected()
        }
    }

    private func enqueue() {
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        manager.enqueue(targets.map(\.id))
        model.clearChecked()
        ClipboardHUD.shared.show(
            "已加入队列 · 共 \(manager.queue.count) 条",
            // One row is named; a batch is counted, because a summary of five entries
            // would only be a summary of the first.
            detail: targets.count == 1 ? targets[0].preview : "本次加入 \(targets.count) 条",
            symbol: "text.append",
            style: .success
        )
    }

    /// ⌥↩. On the queue tab it is deliberately inert: every row there is already in the
    /// queue, and `enqueue` would move the selection to the back of the dispensing order
    /// — a silent reshuffle, reported by the HUD as an addition. Reordering is what the
    /// context menu's 上移 / 下移 are for, which is why this only says so.
    private func enqueueSelected() {
        guard model.filter == .queue else {
            enqueue()
            return
        }
        guard !model.actionTargets.isEmpty else { return }
        ClipboardHUD.shared.show("已在队列中", symbol: "text.append")
    }

    /// ⌘⌫ on the queue tab. The entries stay in the history — this is a reordering
    /// surface, and the one destructive key in the panel should not quietly mean two
    /// different things depending on which tab is open.
    private func dequeueSelected() {
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        for record in targets { manager.removeFromQueue(record.id) }
        model.clearChecked()
        ClipboardHUD.shared.show(
            "已移出队列 · 还剩 \(manager.queue.count) 条",
            detail: targets.count == 1 ? targets[0].preview : nil,
            symbol: "text.append"
        )
    }

    /// The queue tab's row button — the hover control where every other tab has a trash.
    ///
    /// One row, never the ticked set, like the other two row buttons; and the same removal
    /// ⌘⌫ and the context menu perform there, because a button that destroyed the history
    /// entry while every key beside it only took the row out of the queue would be the one
    /// irreversible thing on the tab.
    private func dequeueRow(_ index: Int) {
        guard model.results.indices.contains(index) else { return }
        model.select(index)
        let record = model.results[index]
        manager.removeFromQueue(record.id)
        ClipboardHUD.shared.show(
            "已移出队列 · 还剩 \(manager.queue.count) 条",
            detail: record.preview,
            symbol: "text.append"
        )
    }

    /// One call for the whole selection, not one per row: the store keeps a single undo
    /// buffer, and a row-at-a-time loop would commit all but the last one on the way.
    private func deleteSelected() {
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        manager.delete(targets.map(\.id))
        model.clearChecked()
    }

    /// ⌘Z. Silent when the window has passed rather than reporting a failure — by then
    /// the deletion is simply history, and there is nothing the user can do about it.
    /// Returns how many rows came back, which is also how the key decides whether it was
    /// the panel's ⌘Z at all — see `handle(_:)`.
    @discardableResult
    private func undoDelete() -> Int {
        manager.undoDelete()
    }

    private func togglePin() {
        guard let record = model.selected else { return }
        manager.togglePin(record.id)
    }

    // MARK: - Keyboard

    /// How many rows PgUp / PgDn move by.
    private static let pageStep = 10

    /// Arrow keys and Return have to be intercepted before the search field sees them,
    /// which a local monitor does and a SwiftUI `.onKeyPress` on a focused text field
    /// does not do reliably.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
        // The window server stamps every mouse event with the modifiers held at the
        // time, which is the only account of them the panel can rely on — see
        // `modifiersHeld()`. Recorded here, before the event reaches SwiftUI, because a
        // tap gesture does not carry the event that triggered it.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            self?.clickModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)

        // The first-run card is dismissed by whatever key was pressed, and then that key
        // goes on to do its ordinary job — anything else would make an introduction into a
        // modal to be got past. Escape and `?` are the two exceptions, because both
        // already *mean* "close this": they are spent on the card and go no further.
        if model.dismissOnboarding() {
            if event.keyCode == 53 { return true }
            if event.keyCode == 44, shift, !command, !option { return true }
        }

        switch event.keyCode {
        case 126:  // up
            if command { model.moveToEdge(-1) } else { model.move(by: -1, extending: shift) }
            return true
        case 125:  // down
            if command { model.moveToEdge(1) } else { model.move(by: 1, extending: shift) }
            return true
        // Page and Home / End. A ten-row step rather than a measured screenful: the list
        // scrolls the selection to the centre, so "a page" is a feel rather than a
        // geometry, and ten rows is about what the panel shows at once.
        case 116:  // page up
            model.move(by: -Self.pageStep, extending: shift)
            return true
        case 121:  // page down
            model.move(by: Self.pageStep, extending: shift)
            return true
        // Home and End only with an empty field, like ← and →: with something typed they
        // are the search box's own "start of line" / "end of line", and taking those away
        // would leave no way to get back to the front of a query to fix it. PgUp and PgDn
        // are left alone — a single-line field has nothing to page.
        case 115 where model.query.isEmpty:  // home
            model.moveToEdge(-1)
            return true
        case 119 where model.query.isEmpty:  // end
            model.moveToEdge(1)
            return true
        // ← and → open and close the preview — but only with an empty field, where they
        // are not the cursor keys of the search box the panel puts the focus in.
        case 124 where model.query.isEmpty && !command && !option:  // right
            model.pinPreview()
            return true
        case 123 where model.query.isEmpty && !command && !option:  // left
            model.unpinPreview()
            return true
        case 0 where command && model.query.isEmpty:  // ⌘A
            // With something typed, ⌘A is the field's own "select all the text", which
            // is what anyone about to retype a query reaches for.
            model.toggleSelectAll()
            return true
        case 6 where command:  // ⌘Z
            // Deliberately not guarded by an empty field. The HUD promises 「⌘Z 撤销」 for
            // every deletion, and deleting a row you have just searched for is the most
            // common way to reach one — so a ⌘Z that did nothing there would be the panel
            // going back on what it had just said.
            //
            // Which is safe because the store's undo is its own test: it restores the
            // pending batch or, once the ten-second window has passed, nothing at all.
            // Nothing restored with a query in the field means the key was never ours, and
            // it falls through to the field's own text undo. With an empty field there is
            // no text to undo, so it is swallowed either way rather than beeping.
            if undoDelete() > 0 { return true }
            return model.query.isEmpty
        case 36, 76:  // return, keypad enter
            // The setting swaps the pair rather than taking either away: whichever ↩ is
            // not, ⌘↩ is. Under 「直接粘贴」 that makes ⌘↩ the plain-text paste it has
            // always been; under 「仅复制」 it is the paste itself.
            if option {
                enqueueSelected()
            } else if returnPastes {
                paste(plainTextOnly: command)
            } else if command {
                paste(plainTextOnly: false)
            } else {
                copySelected()
            }
            return true
        case 53:  // escape
            if model.showingShortcuts {
                model.showingShortcuts = false
            } else if !model.query.isEmpty {
                model.query = ""
            } else if !model.checked.isEmpty {
                model.clearChecked()
            } else {
                hide()
            }
            return true
        case 48:  // tab
            model.cycleFilter(backwards: shift)
            return true
        case 51 where command:  // ⌘⌫
            // On the queue tab the obvious meaning of "delete this row" is to take it
            // out of the queue, not to destroy the entry it points at.
            if model.filter == .queue { dequeueSelected() } else { deleteSelected() }
            return true
        // `?` — the shortcut sheet. Only with an empty field, because with a query in it
        // the same key is a character being typed.
        case 44 where shift && !command && !option && model.query.isEmpty:
            model.showingShortcuts.toggle()
            return true
        case 35 where command:  // ⌘P
            togglePin()
            return true
        case 8 where command:  // ⌘C
            copyOnly()
            return true
        case 40 where command && shift:  // ⌘⇧K
            manager.clearQueue()
            ClipboardHUD.shared.show("队列已清空", symbol: "trash")
            return true
        default:
            break
        }

        // ⌘1 … ⌘9 — straight to the nth row, the fastest path for a known position.
        if command, let characters = event.charactersIgnoringModifiers,
           let digit = Int(characters), (1...9).contains(digit) {
            let index = digit - 1
            guard model.results.indices.contains(index) else { return true }
            model.clearChecked()
            model.select(index)
            paste(plainTextOnly: false)
            return true
        }

        return false
    }
}

/// Callbacks the SwiftUI layer needs. A plain struct of closures keeps the view free
/// of any reference to AppKit plumbing.
struct ClipboardPanelActions {
    var paste: (Bool) -> Void
    var pasteKeepingOpen: () -> Void
    /// 「粘贴为…」: paste the targets' text, rewritten.
    var pasteTransformed: (PasteTransform) -> Void
    var copyOnly: () -> Void
    /// What ↩ does under the current setting: paste, or copy and close. For the places
    /// that mean "the default action" rather than one of the two by name.
    var returnAction: () -> Void
    var enqueue: () -> Void
    var delete: () -> Void
    /// Queue tab only: what ⌘⌫ means there — the selection leaves the dispensing order
    /// and stays in the history.
    var dequeue: () -> Void
    var togglePin: () -> Void
    var clearQueue: () -> Void
    /// Queue tab only: drop one entry out of the dispensing order, history untouched.
    var removeFromQueue: (UUID) -> Void
    /// Queue tab only: swap one entry with its neighbour. `true` moves it towards the
    /// front, which is where the next paste comes from.
    var moveInQueue: (UUID, Bool) -> Void
    var toggleShortcuts: () -> Void
    var toggleChecked: (UUID) -> Void
    /// The row's own hover buttons. Indexed rather than taking the current selection, and
    /// separate from `togglePin` / `delete` for the same reason: they act on one row,
    /// never on whatever happens to be ticked — see `act(onRow:_:)`.
    var togglePinRow: (Int) -> Void
    var deleteRow: (Int) -> Void
    /// Queue tab only: what the row's second hover button does there. The history entry
    /// is left alone, exactly as ⌘⌫ and the context menu leave it.
    var dequeueRow: (Int) -> Void
    var selectIndex: (Int) -> Void
    var activateRow: (Int) -> Void
    var hoverIndex: (Int) -> Void
    var hoverEnded: (Int) -> Void
    var edit: () -> Void
    /// A row started being dragged out. Returns what the drag carries, and arms the
    /// exemption that keeps the panel up while it is in flight.
    var dragBegan: (ClipRecord) -> NSItemProvider
    /// 收藏 tab only: put the row currently being dragged at this place in the band.
    var movePinnedRow: (Int) -> Void
    /// 收藏 tab only: move one row a single step through the band. `true` is towards the
    /// top. The context menu's half of what dragging does.
    var reorderPinned: (Int, Bool) -> Void
    /// Something was dropped onto the list from another application.
    var saveDropped: ([NSItemProvider]) -> Void
    var dismissOnboarding: () -> Void
    /// Replays the operation retained after a failed paste/copy transaction.
    var retryPaste: () -> Void
    var skipInvalidPaste: () -> Void
    var openAccessibilitySettings: () -> Void
    var dismissPasteIssue: () -> Void
    var close: () -> Void
}
