import XCTest
@testable import Sous

final class ShoppingListLogicTests: XCTestCase {
    func testUncheckedCountIgnoresChecked() {
        let items = [
            ShoppingItem(id: UUID(), name: "soy sauce", qty: nil, section: "pantry", checked: false),
            ShoppingItem(id: UUID(), name: "eggs", qty: nil, section: "dairy", checked: true),
        ]
        XCTAssertEqual(uncheckedCount(items), 1)
    }

    func testGroupedItemsOrderSectionsCanonically() {
        let items = [
            ShoppingItem(id: UUID(), name: "chili", qty: nil, section: "pantry", checked: false),
            ShoppingItem(id: UUID(), name: "chicken breast", qty: nil, section: "meat", checked: false),
            ShoppingItem(id: UUID(), name: "tomato", qty: nil, section: "produce", checked: false),
        ]
        let grouped = groupedShoppingItems(items)
        XCTAssertEqual(grouped.map(\.section), ["produce", "meat", "pantry"])
    }

    func testGroupedItemsCaseInsensitiveSectionMatching() {
        // Real cloud data (2026-07-16 exit check) used lowercase single-word sections
        // ("meat", "produce"), not the exact "Meat & seafood" prose plan-week.md
        // suggests to the brain — ordering must tolerate both.
        let items = [
            ShoppingItem(id: UUID(), name: "milk", qty: nil, section: "Dairy & fridge", checked: false),
            ShoppingItem(id: UUID(), name: "carrot", qty: nil, section: "Produce", checked: false),
        ]
        let grouped = groupedShoppingItems(items)
        XCTAssertEqual(grouped.map(\.section), ["Produce", "Dairy & fridge"])
    }

    func testUnrecognizedSectionSortsLast() {
        let items = [
            ShoppingItem(id: UUID(), name: "mystery item", qty: nil, section: "misc", checked: false),
            ShoppingItem(id: UUID(), name: "carrot", qty: nil, section: "produce", checked: false),
        ]
        let grouped = groupedShoppingItems(items)
        XCTAssertEqual(grouped.map(\.section), ["produce", "misc"])
    }

    func testCheckedItemsSinkWithinSection() {
        let items = [
            ShoppingItem(id: UUID(), name: "zzz-checked", qty: nil, section: "pantry", checked: true),
            ShoppingItem(id: UUID(), name: "aaa-unchecked", qty: nil, section: "pantry", checked: false),
        ]
        let grouped = groupedShoppingItems(items)
        XCTAssertEqual(grouped.first?.items.map(\.name), ["aaa-unchecked", "zzz-checked"])
    }

    func testGroupedItemsMergesDifferentCasingOfSameSection() {
        // Items with the same canonical section but different casing
        // (e.g., "produce" vs "Produce") must merge into a single group.
        let items = [
            ShoppingItem(id: UUID(), name: "carrot", qty: nil, section: "produce", checked: false),
            ShoppingItem(id: UUID(), name: "lettuce", qty: nil, section: "Produce", checked: false),
        ]
        let grouped = groupedShoppingItems(items)
        XCTAssertEqual(grouped.count, 1, "Items with different casing should merge into one group")
        XCTAssertEqual(grouped.first?.items.count, 2, "Both items should be in the merged group")
        XCTAssertEqual(grouped.first?.items.map(\.name).sorted(), ["carrot", "lettuce"])
    }
}
