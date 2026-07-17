import Foundation

/// Canonical section ordering, matching what worker/skills/plan-week.md instructs the
/// brain to use — but keyed case-insensitively since real cloud data has been observed
/// using lowercase single-word sections ("meat") rather than the exact prose labels
/// ("Meat & seafood"). Unrecognized sections sort after all known ones (rank 99).
private let sectionRank: [String: Int] = [
    "produce": 0,
    "meat": 1, "meat & seafood": 1, "seafood": 1,
    "dairy": 2, "dairy & fridge": 2, "fridge": 2,
    "pantry": 3,
    "breakfast": 4,
]

private func sectionSortKey(_ section: String?) -> Int {
    let key = (section ?? "").lowercased().trimmingCharacters(in: .whitespaces)
    return sectionRank[key] ?? 99
}

struct ShoppingSectionGroup: Equatable {
    let section: String
    let items: [ShoppingItem]
}

/// Groups items by their raw `section` string (display-cased verbatim, whatever the DB
/// has), sorted into canonical order. Within each section, unchecked items come first
/// and checked items sink to the bottom (not to a separate global done-pile), so
/// everything stays findable by aisle even once partially checked off.
func groupedShoppingItems(_ items: [ShoppingItem]) -> [ShoppingSectionGroup] {
    let bySection = Dictionary(grouping: items) { $0.section ?? "" }
    return bySection
        .map { section, items -> ShoppingSectionGroup in
            let sorted = items.sorted { a, b in
                if a.checked != b.checked { return !a.checked }
                return a.name < b.name
            }
            return ShoppingSectionGroup(section: section, items: sorted)
        }
        .sorted { a, b in
            let rankA = sectionSortKey(a.section)
            let rankB = sectionSortKey(b.section)
            if rankA != rankB { return rankA < rankB }
            return a.section < b.section
        }
}

func uncheckedCount(_ items: [ShoppingItem]) -> Int {
    items.filter { !$0.checked }.count
}
