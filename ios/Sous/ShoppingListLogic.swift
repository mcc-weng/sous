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

/// Normalize a section string by lowercasing and trimming whitespace.
/// Used consistently for both grouping and sorting to ensure sections with
/// different casing (e.g., "produce" vs "Produce") are treated identically.
private func normalizedSectionKey(_ section: String?) -> String {
    (section ?? "").lowercased().trimmingCharacters(in: .whitespaces)
}

private func sectionSortKey(_ section: String?) -> Int {
    return sectionRank[normalizedSectionKey(section)] ?? 99
}

struct ShoppingSectionGroup: Equatable {
    let section: String
    let items: [ShoppingItem]
}

/// Groups items by their normalized section key (lowercased and trimmed), ensuring items with
/// the same canonical section but different casing merge into one group. Within each section,
/// unchecked items come first and checked items sink to the bottom (not to a separate global
/// done-pile), so everything stays findable by aisle even once partially checked off.
/// The display section name is the first item's raw section value (preserving original casing).
func groupedShoppingItems(_ items: [ShoppingItem]) -> [ShoppingSectionGroup] {
    let byNormalizedSection = Dictionary(grouping: items) { normalizedSectionKey($0.section) }
    return byNormalizedSection
        .map { _, groupItems -> ShoppingSectionGroup in
            let displaySection = groupItems.first?.section ?? ""
            let sorted = groupItems.sorted { a, b in
                if a.checked != b.checked { return !a.checked }
                return a.name < b.name
            }
            return ShoppingSectionGroup(section: displaySection, items: sorted)
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
