import Foundation

/// Popover section visibility + ordering (Settings → 섹션). See `PanelSection`.
extension UsageStore {
    func isVisible(_ section: PanelSection) -> Bool {
        !hiddenSectionsRaw.split(separator: ",").contains(Substring(section.rawValue))
    }
    func setVisible(_ section: PanelSection, _ visible: Bool) {
        var hidden = Set(hiddenSectionsRaw.split(separator: ",").map(String.init))
        if visible { hidden.remove(section.rawValue) } else { hidden.insert(section.rawValue) }
        hiddenSectionsRaw = hidden.sorted().joined(separator: ",")
    }

    /// Sections in display order (saved order first, then any new ones in default order).
    var orderedSections: [PanelSection] {
        let saved = sectionOrderRaw.split(separator: ",").compactMap { PanelSection(rawValue: String($0)) }
        return saved + PanelSection.allCases.filter { !saved.contains($0) }
    }
    /// Move a section up (delta -1) or down (delta +1).
    func moveSection(_ section: PanelSection, by delta: Int) {
        var order = orderedSections
        guard let i = order.firstIndex(of: section), order.indices.contains(i + delta) else { return }
        order.swapAt(i, i + delta)
        sectionOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }

    /// Drag-and-drop reorder: place `moved` just before `target`.
    func moveSection(_ moved: PanelSection, before target: PanelSection) {
        guard moved != target else { return }
        var order = orderedSections.filter { $0 != moved }
        guard let idx = order.firstIndex(of: target) else { return }
        order.insert(moved, at: idx)
        sectionOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }
}
