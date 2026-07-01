import AppKit

struct ChooserItem {
    let text: String
    let subText: String
    let image: NSImage?
    let index: Int
}

/// Borderless panel that can take keyboard focus without activating the app —
/// the window underneath stays focused, which is what makes auto-paste land
/// in the right place.
final class ChooserPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Spotlight-style chooser: search field on top, results below.
/// Type to filter, ↑/↓ to move, Enter to pick, Esc to cancel.
final class Chooser: NSObject, NSTextFieldDelegate, NSTableViewDataSource,
                     NSTableViewDelegate, NSWindowDelegate {
    static let shared = Chooser()

    private let panelWidth: CGFloat = 580
    private let rowHeight: CGFloat = 40
    private let fieldAreaHeight: CGFloat = 52
    private let maxRows = 9

    private var panel: ChooserPanel!
    private var field: NSTextField!
    private var scroll: NSScrollView!
    private var table: NSTableView!

    private var allItems: [ChooserItem] = []
    private var filtered: [ChooserItem] = []
    private var onPick: ((Int?) -> Void)?

    func show(items: [ChooserItem], placeholder: String, onPick: @escaping (Int?) -> Void) {
        if panel == nil { buildPanel() }
        // Replace any pending callback (e.g. re-invoking the hotkey while open).
        self.onPick = onPick
        allItems = items
        field.stringValue = ""
        field.placeholderString = placeholder
        applyFilter("")
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func finish(with index: Int?) {
        guard let cb = onPick else { return }
        onPick = nil
        panel.orderOut(nil)
        cb(index)
    }

    // ------------------------------------------------------------- UI setup

    private func buildPanel() {
        let height = fieldAreaHeight + CGFloat(maxRows) * rowHeight + 8
        panel = ChooserPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: height))
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        field = NSTextField(frame: NSRect(x: 16, y: height - 40, width: panelWidth - 32, height: 28))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .light)
        field.delegate = self
        field.autoresizingMask = [.width, .minYMargin]
        effect.addSubview(field)

        let sep = NSBox(frame: NSRect(x: 0, y: height - fieldAreaHeight, width: panelWidth, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .minYMargin]
        effect.addSubview(sep)

        table = NSTableView(frame: .zero)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 0, height: 0)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = panelWidth
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll = NSScrollView(frame: NSRect(x: 0, y: 4, width: panelWidth,
                                            height: height - fieldAreaHeight - 8))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        effect.addSubview(scroll)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let x = f.midX - panelWidth / 2
        let y = f.minY + f.height * 0.62 - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // ------------------------------------------------------------ filtering

    private func applyFilter(_ query: String) {
        let q = query.lowercased()
        if q.isEmpty {
            filtered = allItems
        } else {
            filtered = allItems.filter {
                $0.text.lowercased().contains(q) || $0.subText.lowercased().contains(q)
            }
        }
        table.reloadData()
        if !filtered.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(field.stringValue)
    }

    // ------------------------------------------------------------- keyboard

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            pickSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(with: nil)
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let row = max(0, min(filtered.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func pickSelected() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else {
            finish(with: nil)
            return
        }
        finish(with: filtered[row].index)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < filtered.count else { return }
        finish(with: filtered[row].index)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere cancels, like Spotlight.
        finish(with: nil)
    }

    // ----------------------------------------------------------- table view

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let item = filtered[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: rowHeight))
            cell.identifier = id

            let iv = NSImageView(frame: NSRect(x: 14, y: 8, width: 24, height: 24))
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.tag = 1
            cell.addSubview(iv)

            let title = NSTextField(labelWithString: "")
            title.frame = NSRect(x: 48, y: 19, width: panelWidth - 62, height: 17)
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.autoresizingMask = [.width]
            title.tag = 2
            cell.addSubview(title)

            let sub = NSTextField(labelWithString: "")
            sub.frame = NSRect(x: 48, y: 3, width: panelWidth - 62, height: 15)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.autoresizingMask = [.width]
            sub.tag = 3
            cell.addSubview(sub)
        }
        (cell.viewWithTag(1) as? NSImageView)?.image = item.image
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = item.text
        (cell.viewWithTag(3) as? NSTextField)?.stringValue = item.subText
        return cell
    }
}
