//
//  SessionsTableViewController.swift
//  WWDC
//
//  Created by Guilherme Rambo on 22/04/17.
//  Copyright © 2017 Guilherme Rambo. All rights reserved.
//

import Cocoa
import RxSwift
import RxCocoa
import RealmSwift
import ConfCore
import os.log

protocol SessionIdentifiable {
    var sessionIdentifier: String { get }
}

struct SessionIdentifier: SessionIdentifiable {
    let sessionIdentifier: String

    init(_ string: String) {
        sessionIdentifier = string
    }
}

extension SessionViewModel: SessionIdentifiable {
    var sessionIdentifier: String {
        return identifier
    }
}

protocol SessionsTableViewControllerDelegate: class {

    func sessionTableViewContextMenuActionWatch(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionUnWatch(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionFavorite(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionRemoveFavorite(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionDownload(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionCancelDownload(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionRevealInFinder(viewModels: [SessionViewModel])
}

class SessionsTableViewController: NSViewController {

    fileprivate struct Metrics {
        static let headerRowHeight: CGFloat = 20
        static let sessionRowHeight: CGFloat = 64
    }

    private let disposeBag = DisposeBag()

    weak var delegate: SessionsTableViewControllerDelegate?

    var selectedSession = Variable<SessionViewModel?>(nil)

    let style: SessionsListStyle

    fileprivate lazy var searchQueue: DispatchQueue = DispatchQueue(label: "Search", qos: .userInteractive)

    var storage: Storage?

//    func forceRowIntoList(for viewModel: SessionViewModel) -> Bool {
//        forcedIntoListQuery =
//    }

    var forcedIntoListQuery: NSPredicate? {
        didSet {
            updateEffectiveQuery()
        }
    }

    var filterQuery: NSPredicate? {
        didSet {
            updateEffectiveQuery()
        }
    }

    func updateEffectiveQuery() {
        guard let filterQuery = filterQuery else { effectiveQuery = nil; return }
        guard let forcedIntoListQuery = forcedIntoListQuery else { effectiveQuery = filterQuery; return }

        effectiveQuery = NSCompoundPredicate(orPredicateWithSubpredicates: [filterQuery, forcedIntoListQuery])
    }

    var effectiveQuery: NSPredicate? {
        didSet {
            guard let effectiveQuery = effectiveQuery else {
                searchResults = nil
                return
            }

            searchQueue.async { [unowned self] in
                do {
                    let realm = try Realm(configuration: self.storage!.realmConfig)

                    let football = ThreadSafeReference(to: realm.objects(Session.self).filter(effectiveQuery))
                    DispatchQueue.main.async {
                        self.searchResults = self.storage!.realm.resolve(football)
                    }
                } catch {
                    os_log("Failed to initialize Realm for searching: %{public}@",
                           log: .default,
                           type: .error,
                           String(describing: error))
                    LoggingHelper.registerError(error, info: ["when": "Searching"])
                }
            }
        }
    }

    func setSearchResults(_ searchResults: Results<Session>?, animated: Bool, selecting session: SessionIdentifiable) {
        _searchResults = searchResults
        updateWith(searchResults: searchResults, animated: animated, selecting: session)
    }
    private var _searchResults: Results<Session>?
    private(set) var searchResults: Results<Session>? {
        get { return _searchResults }
        set {
            _searchResults = newValue
            updateWith(searchResults: newValue, animated: true, selecting: nil)
        }
    }

    var sessionRowProvider: SessionRowProvider? {
        didSet {
            allRows = sessionRowProvider?.sessionRows() ?? []
        }
    }

    private var allRows: [SessionRow] = []

    func isSessionVisible(for session: SessionIdentifiable) -> Bool {
        return displayedRows.contains { row -> Bool in
            if case .session(let viewModel) = row.kind {
                return viewModel.identifier == session.sessionIdentifier
            }
            return false
        }
    }

    func canDisplay(session: SessionIdentifiable) -> Bool {
        return allRows.contains { row -> Bool in
            if case .session(let viewModel) = row.kind {
                return viewModel.identifier == session.sessionIdentifier
            }
            return false
        }
    }

    private(set) var displayedRows: [SessionRow] = []

    // MARK: - Displaying Rows

    lazy var displayedRowsLock: DispatchQueue = {

        return DispatchQueue(label: "io.wwdc.sessiontable.displayedrows.lock\(self.hashValue)", qos: .userInteractive)
    }()

    private var hasPerformedInitialRowDisplay = false

    private func performInitialRowDisplayIfNeeded(displaying rows: [SessionRow]) -> Bool {

        guard !hasPerformedInitialRowDisplay else { return true }
        hasPerformedInitialRowDisplay = true

        displayedRowsLock.suspend()

        displayedRows = rows

        NSAnimationContext.runAnimationGroup({ (context) in
            context.duration = 0
            tableView.reloadData()
        }, completionHandler: {

            if let deferredSelection = self.initialSelection {
                self.initialSelection = nil
                self.selectSessionImmediately(with: deferredSelection)
            }

            // Ensure an initial selection
            if self.tableView.selectedRow == -1,
                let defaultIndex = rows.firstSessionRowIndex() {

                self.tableView.selectRowIndexes(IndexSet(integer: defaultIndex), byExtendingSelection: false)
            }

            self.scrollView.animator().alphaValue = 1
            self.tableView.allowsEmptySelection = false
            self.displayedRowsLock.resume()
        })

        return false
    }

    func setDisplayedRows(_ newValue: [SessionRow], animated: Bool, overridingSelectionWith session: SessionIdentifiable?) {

        guard performInitialRowDisplayIfNeeded(displaying: newValue) else { return }

        // Dismiss the menu when the displayed rows are about to change otherwise it will crash
        tableView.menu?.cancelTrackingWithoutAnimation()

        displayedRowsLock.async {

            let oldValue = self.displayedRows

            // Same elements, same order: https://github.com/apple/swift/blob/master/stdlib/public/core/Arrays.swift.gyb#L2203
            if oldValue == newValue { return }

            let oldRowsSet = Set(oldValue.enumerated().map { IndexedSessionRow(sessionRow: $1, index: $0) })
            let newRowsSet = Set(newValue.enumerated().map { IndexedSessionRow(sessionRow: $1, index: $0) })

            let removed = oldRowsSet.subtracting(newRowsSet)
            let added = newRowsSet.subtracting(oldRowsSet)

            let removedIndexes = IndexSet(removed.map { $0.index })
            let addedIndexes = IndexSet(added.map { $0.index })

            // Only reload rows if their relative positioning changes. This prevents
            // cell contents from flashing when cells are unnecessarily reloaded
            var needReloadedIndexes = IndexSet()

            let sortedOldRows = oldRowsSet.intersection(newRowsSet).sorted(by: { (row1, row2) -> Bool in
                return row1.index < row2.index
            })

            let sortedNewRows = newRowsSet.intersection(oldRowsSet).sorted(by: { (row1, row2) -> Bool in
                return row1.index < row2.index
            })

            for (oldSessionRowIndex, newSessionRowIndex) in zip(sortedOldRows, sortedNewRows) where oldSessionRowIndex.sessionRow != newSessionRowIndex.sessionRow {
                needReloadedIndexes.insert(newSessionRowIndex.index)
            }

            DispatchQueue.main.sync {

                var selectedIndexes = IndexSet()
                if let session = session,
                    let overrideIndex = newValue.index(of: session) {

                    selectedIndexes.insert(overrideIndex)
                } else {
                    // Preserve selected rows if possible
                    let selectedRows = self.tableView.selectedRowIndexes.compactMap { (index) -> IndexedSessionRow? in
                        guard index < oldValue.endIndex else { return nil }
                        return IndexedSessionRow(sessionRow: oldValue[index], index: index)
                    }

                    selectedIndexes = IndexSet(newRowsSet.intersection(selectedRows).map { $0.index })
                }

                if selectedIndexes.isEmpty, let defaultIndex = newValue.firstSessionRowIndex() {
                    selectedIndexes.insert(defaultIndex)
                }

                NSAnimationContext.beginGrouping()
                let context = NSAnimationContext.current
                if !animated {
                    context.duration = 0
                }

                context.completionHandler = {
                    NSAnimationContext.runAnimationGroup({ (context) in
                        context.allowsImplicitAnimation = animated
                        self.tableView.scrollRowToCenter(selectedIndexes.first ?? 0)
                    }, completionHandler: nil)
                }

                self.tableView.beginUpdates()

                self.tableView.removeRows(at: removedIndexes, withAnimation: [NSTableView.AnimationOptions.slideLeft])

                self.tableView.insertRows(at: addedIndexes, withAnimation: [NSTableView.AnimationOptions.slideDown])

                // insertRows(::) and removeRows(::) will query the delegate for the row count at the beginning
                // so we delay updating the data model until after those methods have done their thing
                self.displayedRows = newValue

                // This must be after you update the backing model
                self.tableView.reloadData(forRowIndexes: needReloadedIndexes, columnIndexes: IndexSet(integersIn: 0..<1))

                self.tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)

                self.tableView.endUpdates()
                NSAnimationContext.endGrouping()
            }
        }
    }

    init(style: SessionsListStyle) {
        self.style = style

        super.init(nibName: nil, bundle: nil)

        identifier = NSUserInterfaceItemIdentifier(rawValue: "videosList")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var initialSelection: SessionIdentifiable?

    private func selectSessionImmediately(with identifier: SessionIdentifiable) {

        guard let index = displayedRows.index(where: { row in
            guard case .session(let viewModel) = row.kind else { return false }

            return viewModel.identifier == identifier.sessionIdentifier
        }) else {
            return
        }

        tableView.scrollRowToCenter(index)
        tableView.selectRowIndexes(IndexSet([index]), byExtendingSelection: false)
    }

    func select(session: SessionIdentifiable) {

        let needsToClearSearchToAllowSelection = !isSessionVisible(for: session) && canDisplay(session: session)

        // If we haven't yet displayed our rows, likely because we haven't come on screen
        // yet. We defer scrolling to the requested identifier until that time.
        guard hasPerformedInitialRowDisplay else {
            searchController.resetFilters()
            _searchResults = nil
            initialSelection = session
            return
        }

        if needsToClearSearchToAllowSelection {
            searchController.resetFilters()
            setSearchResults(nil, animated: view.window != nil, selecting: session)
        } else {
            selectSessionImmediately(with: session)
        }
    }

    func scrollToToday() {

        sessionRowProvider?.sessionRowIdentifierForToday().flatMap { select(session: $0) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        view.window?.makeFirstResponder(tableView)

        performFirstUpdateIfNeeded()
    }

    /// This function is meant to ensure the table view gets populated
    /// even if its data model gets added while it is offscreen. Specifically,
    /// when this table view is not the initial active tab.
    private func performFirstUpdateIfNeeded() {
        guard !hasPerformedInitialRowDisplay else { return }

        updateWith(searchResults: searchResults, selecting: nil)
    }

    func configureRows(weekdayIsVisible: Bool) {

        for row in allRows {
            if case .session(let viewModel) = row.kind {
                viewModel.showsWeekdayInContext = weekdayIsVisible
            }
        }
    }

    private func updateWith(searchResults: Results<Session>?, animated: Bool = true, selecting session: SessionIdentifiable?) {
        guard view.window != nil else { return }

        configureRows(weekdayIsVisible: !(searchResults?.isEmpty ?? true))

        guard let results = searchResults else {

            if !allRows.isEmpty {
                setDisplayedRows(allRows, animated: animated, overridingSelectionWith: session)
            }

            return
        }

        guard let sessionRowProvider = sessionRowProvider else { return }

        let sortingFunction = sessionRowProvider.sessionSortingFunction

        let sessionRows: [SessionRow] = results.sorted(by: sortingFunction).compactMap { session in
            guard let viewModel = SessionViewModel(session: session) else { return nil }

            for row in allRows {
                if case .session(let sessionViewModel) = row.kind, sessionViewModel.session.identifier == session.identifier {
                    return row
                }
            }

            return SessionRow(viewModel: viewModel)
        }

        setDisplayedRows(sessionRows, animated: animated, overridingSelectionWith: session)
    }

    lazy var searchController: SearchFiltersViewController = {
        return SearchFiltersViewController.loadFromStoryboard()
    }()

    lazy var tableView: WWDCTableView = {
        let v = WWDCTableView()

        // We control the intial selection during initialization
        v.allowsEmptySelection = true

        v.wantsLayer = true
        v.focusRingType = .none
        v.allowsMultipleSelection = true
        v.backgroundColor = .listBackground
        v.headerView = nil
        v.rowHeight = Metrics.sessionRowHeight
        v.autoresizingMask = [.width, .height]
        v.floatsGroupRows = true
        v.gridStyleMask = .solidHorizontalGridLineMask
        v.gridColor = .darkGridColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "session"))
        v.addTableColumn(column)

        return v
    }()

    lazy var scrollView: NSScrollView = {
        let v = NSScrollView()

        v.focusRingType = .none
        v.backgroundColor = .listBackground
        v.borderType = .noBorder
        v.documentView = self.tableView
        v.hasVerticalScroller = true
        v.hasHorizontalScroller = false
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alphaValue = 0

        return v
    }()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: MainWindowController.defaultRect.height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.darkWindowBackground.cgColor
        view.widthAnchor.constraint(lessThanOrEqualToConstant: 675).isActive = true

        scrollView.frame = view.bounds
        tableView.frame = view.bounds

        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        view.addSubview(scrollView)
        view.addSubview(searchController.view)

        searchController.view.translatesAutoresizingMaskIntoConstraints = false

        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true

        scrollView.topAnchor.constraint(equalTo: searchController.view.bottomAnchor).isActive = true

        searchController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        searchController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        searchController.view.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self

        setupContextualMenu()

        tableView.rx.selectedRow.map { index -> SessionViewModel? in
            guard let index = index else { return nil }
            guard case .session(let viewModel) = self.displayedRows[index].kind else { return nil }

            return viewModel
            }.bind(to: selectedSession).disposed(by: disposeBag)
    }

    // MARK: - Contextual menu

    fileprivate enum ContextualMenuOption: Int {
        case watched = 1000
        case unwatched = 1001
        case favorite = 1002
        case removeFavorite = 1003
        case download = 1004
        case cancelDownload = 1005
        case revealInFinder = 1006
    }

    private func setupContextualMenu() {
        let contextualMenu = NSMenu(title: "TableView Menu")

        let watchedMenuItem = NSMenuItem(title: "Mark as Watched", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        watchedMenuItem.option = .watched
        contextualMenu.addItem(watchedMenuItem)

        let unwatchedMenuItem = NSMenuItem(title: "Mark as Unwatched", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        unwatchedMenuItem.option = .unwatched
        contextualMenu.addItem(unwatchedMenuItem)

        contextualMenu.addItem(.separator())

        let favoriteMenuItem = NSMenuItem(title: "Add to Favorites", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        favoriteMenuItem.option = .favorite
        contextualMenu.addItem(favoriteMenuItem)

        let removeFavoriteMenuItem = NSMenuItem(title: "Remove From Favorites", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        removeFavoriteMenuItem.option = .removeFavorite
        contextualMenu.addItem(removeFavoriteMenuItem)

        contextualMenu.addItem(.separator())

        let downloadMenuItem = NSMenuItem(title: "Download", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        downloadMenuItem.option = .download
        contextualMenu.addItem(downloadMenuItem)

        let cancelDownloadMenuItem = NSMenuItem(title: "Cancel Download", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        contextualMenu.addItem(cancelDownloadMenuItem)
        cancelDownloadMenuItem.option = .cancelDownload

        let revealInFinderMenuItem = NSMenuItem(title: "Reveal in Finder", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        contextualMenu.addItem(revealInFinderMenuItem)
        revealInFinderMenuItem.option = .revealInFinder

        tableView.menu = contextualMenu
    }

    private func selectedRowIndexes() -> IndexSet {
        let clickedRow = tableView.clickedRow
        let selectedRowIndexes = tableView.selectedRowIndexes

        if clickedRow < 0 || selectedRowIndexes.contains(clickedRow) {
            return selectedRowIndexes
        } else {
            return IndexSet(integer: clickedRow)
        }
    }

    @objc private func tableViewMenuItemClicked(_ menuItem: NSMenuItem) {
        var viewModels = [SessionViewModel]()

        selectedRowIndexes().forEach { row in
            guard case .session(let viewModel) = displayedRows[row].kind else { return }

            viewModels.append(viewModel)
        }

        guard !viewModels.isEmpty else { return }

        switch menuItem.option {
        case .watched:
            delegate?.sessionTableViewContextMenuActionWatch(viewModels: viewModels)
        case .unwatched:
            delegate?.sessionTableViewContextMenuActionUnWatch(viewModels: viewModels)
        case .favorite:
            delegate?.sessionTableViewContextMenuActionFavorite(viewModels: viewModels)
        case .removeFavorite:
            delegate?.sessionTableViewContextMenuActionRemoveFavorite(viewModels: viewModels)
        case .download:
            delegate?.sessionTableViewContextMenuActionDownload(viewModels: viewModels)
        case .cancelDownload:
            delegate?.sessionTableViewContextMenuActionCancelDownload(viewModels: viewModels)
        case .revealInFinder:
            delegate?.sessionTableViewContextMenuActionRevealInFinder(viewModels: viewModels)
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        for row in selectedRowIndexes() {
            let sessionRow = displayedRows[row]

            guard case .session(let viewModel) = sessionRow.kind else { break }

            if shouldEnableMenuItem(menuItem: menuItem, viewModel: viewModel) { return true }
        }

        return false
    }

    private func shouldEnableMenuItem(menuItem: NSMenuItem, viewModel: SessionViewModel) -> Bool {

        switch menuItem.option {
        case .watched:
            let canMarkAsWatched = !viewModel.session.isWatched
                && viewModel.session.instances.first?.isCurrentlyLive != true
                && viewModel.session.asset(of: .streamingVideo) != nil

            return canMarkAsWatched
        case .unwatched:
            return viewModel.session.isWatched
        case .favorite:
            return !viewModel.isFavorite
        case .removeFavorite:
            return viewModel.isFavorite
        default: ()
        }

        let remoteURL = viewModel.session.assets.filter("rawAssetType == %@", SessionAssetType.hdVideo.rawValue).first?.remoteURL

        switch (menuItem.option, remoteURL) {
        case let (.download, remoteURL?):
            return !DownloadManager.shared.isDownloading(remoteURL) && DownloadManager.shared.localFileURL(for: viewModel.session) == nil
        case let (.cancelDownload, remoteURL?):
            return DownloadManager.shared.isDownloading(remoteURL)
        case let (.revealInFinder, remoteURL?):
            return DownloadManager.shared.hasVideo(remoteURL)
        default: ()
        }

        return false
    }
}

extension Session {

    var isWatched: Bool {
        if let progress = progresses.first {
            return progress.relativePosition > Constants.watchedVideoRelativePosition
        }

        return false
    }
}

extension SessionsTableViewController: NSTableViewDataSource, NSTableViewDelegate {

    private struct Constants {
        static let sessionCellIdentifier = "sessionCell"
        static let titleCellIdentifier = "titleCell"
        static let rowIdentifier = "row"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let sessionRow = displayedRows[row]

        switch sessionRow.kind {
        case .session(let viewModel):
            return cellForSessionViewModel(viewModel)
        case .sectionHeader(let title):
            return cellForSectionTitle(title)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        var rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: Constants.rowIdentifier), owner: tableView) as? WWDCTableRowView

        if rowView == nil {
            rowView = WWDCTableRowView(frame: .zero)
            rowView?.identifier = NSUserInterfaceItemIdentifier(rawValue: Constants.rowIdentifier)
        }

        switch displayedRows[row].kind {
        case .sectionHeader:
            rowView?.isGroupRowStyle = true
        default:
            rowView?.isGroupRowStyle = false
        }

        return rowView
    }

    private func cellForSessionViewModel(_ viewModel: SessionViewModel) -> SessionTableCellView? {
        var cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: Constants.sessionCellIdentifier), owner: tableView) as? SessionTableCellView

        if cell == nil {
            cell = SessionTableCellView(frame: .zero)
            cell?.identifier = NSUserInterfaceItemIdentifier(rawValue: Constants.sessionCellIdentifier)
        }

        cell?.viewModel = viewModel

        return cell
    }

    private func cellForSectionTitle(_ title: String) -> TitleTableCellView? {
        var cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: Constants.titleCellIdentifier), owner: tableView) as? TitleTableCellView

        if cell == nil {
            cell = TitleTableCellView(frame: .zero)
            cell?.identifier = NSUserInterfaceItemIdentifier(rawValue: Constants.titleCellIdentifier)
        }

        cell?.title = title

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch displayedRows[row].kind {
        case .session:
            return Metrics.sessionRowHeight
        case .sectionHeader:
            return Metrics.headerRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch displayedRows[row].kind {
        case .sectionHeader:
            return false
        case .session:
            return true
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        switch displayedRows[row].kind {
        case .sectionHeader:
            return true
        case .session:
            return false
        }
    }

}

private extension NSMenuItem {

    var option: SessionsTableViewController.ContextualMenuOption {
        get {
            guard let value = SessionsTableViewController.ContextualMenuOption(rawValue: tag) else {
                fatalError("Invalid ContextualMenuOption: \(tag)")
            }

            return value
        }
        set {
            tag = newValue.rawValue
        }
    }

}

private extension Array where Element == SessionRow {

    func index(of session: SessionIdentifiable) -> Int? {
        return index { row in
            guard case .session(let viewModel) = row.kind else { return false }

            return viewModel.identifier == session.sessionIdentifier
        }
    }

    func firstSessionRowIndex() -> Int? {
        return index { row in
            if case .session = row.kind {
                return true
            }
            return false
        }
    }
}
