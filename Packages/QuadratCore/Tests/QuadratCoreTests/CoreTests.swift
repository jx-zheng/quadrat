import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import QuadratCore

final class ByteFormatTests: XCTestCase {
    func testDecimalUnitsMatchFinderStyle() {
        XCTAssertEqual(ByteFormat.bytes(58_000_000_000), "58.0 GB")
        XCTAssertEqual(ByteFormat.bytes(866_000_000_000), "866 GB")
        XCTAssertEqual(ByteFormat.bytes(995_000_000_000), "995 GB")
        XCTAssertEqual(ByteFormat.bytes(18_200_000_000), "18.2 GB")
        XCTAssertEqual(ByteFormat.bytes(6_500_000_000), "6.5 GB")
        XCTAssertEqual(ByteFormat.bytes(1_000_000_000_000), "1.00 TB")
        XCTAssertEqual(ByteFormat.bytes(4_900_000_000_000), "4.90 TB")
        XCTAssertEqual(ByteFormat.bytes(8_000_000_000_000), "8.00 TB")
        XCTAssertEqual(ByteFormat.bytes(12_500_000_000_000), "12.5 TB")
        XCTAssertEqual(ByteFormat.grouped(1_862_400), "1,862,400")
        XCTAssertEqual(ByteFormat.grouped(0), "0")
        XCTAssertEqual(ByteFormat.percent(58_000_000_000, of: 1_000_000_000_000), "5.8%")
        XCTAssertEqual(ByteFormat.percent(870, of: 1000), "87.0%")
    }
}

final class NameBlobTests: XCTestCase {
    func testInternsAfterThirdUse() {
        var blob = NameBlob()
        let first = blob.add("node_modules")
        let second = blob.add("node_modules")
        let third = blob.add("node_modules")
        XCTAssertNotEqual(first.offset, second.offset)
        XCTAssertEqual(third.offset, first.offset)
        XCTAssertEqual(blob.string(offset: third.offset, length: third.length), "node_modules")
        let unique = blob.add("only-once-\(UUID().uuidString)")
        XCTAssertEqual(blob.string(offset: unique.offset, length: unique.length).hasPrefix("only-once-"), true)
    }
}

final class FoldingTests: XCTestCase {
    func testKeepsLargeFilesAndTopThirtyTwo() {
        var files: [Folding.FileChoice] = []
        for index in 0..<40 {
            files.append(.init(key: String(format: "s%02d", index), bytes: 100))
        }
        files.append(.init(key: "big", bytes: 2 << 20))
        let result = Folding.partition(files)
        XCTAssertTrue(result.keep.contains("big"))
        XCTAssertEqual(result.keep.count, 32)
        XCTAssertEqual(result.fold.count, 9)
    }

    func testKeepsEveryFileAtLeastOneMebibyte() {
        let files = (0..<40).map { Folding.FileChoice(key: "f\($0)", bytes: 2 << 20) }
        let result = Folding.partition(files)
        XCTAssertEqual(result.keep.count, 40)
        XCTAssertTrue(result.fold.isEmpty)
    }

    func testKeepsAllWhenFewerThanThirtyTwo() {
        let files = (0..<10).map { Folding.FileChoice(key: "f\($0)", bytes: 10) }
        let result = Folding.partition(files)
        XCTAssertEqual(result.keep.count, 10)
        XCTAssertTrue(result.fold.isEmpty)
    }

    func testTieBreakIsStableByKey() {
        let files = [
            Folding.FileChoice(key: "b", bytes: 10),
            Folding.FileChoice(key: "a", bytes: 10),
            Folding.FileChoice(key: "c", bytes: 10)
        ]
        let first = Folding.partition(files).keep
        let second = Folding.partition(files.reversed()).keep
        XCTAssertEqual(first, second)
    }
}

final class AggregationTests: XCTestCase {
    func testBottomUpTotalsAndTrashSubtract() {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        let docs = store.addNode(parent: root, name: "Docs", allocBytes: 0, logicalBytes: 0, kind: .documents, flags: .directory)
        _ = store.addNode(parent: docs, name: "a.pdf", allocBytes: 8192, logicalBytes: 8192, kind: .documents, flags: [])
        _ = store.addNode(parent: docs, name: "b.pdf", allocBytes: 4096, logicalBytes: 4096, kind: .documents, flags: [])
        let pictures = store.addNode(parent: root, name: "Pictures", allocBytes: 0, logicalBytes: 0, kind: .photos, flags: .directory)
        let photo = store.addNode(parent: pictures, name: "c.jpg", allocBytes: 16384, logicalBytes: 16384, kind: .photos, flags: [])
        store.recomputeAll()
        XCTAssertEqual(store.bytes(docs, .allocated), 12288)
        XCTAssertEqual(store.bytes(root, .allocated), 28672)
        XCTAssertEqual(store.itemCount[Int(docs)], 2)
        XCTAssertEqual(store.itemCount[Int(root)], 3)
        store.removeAndSubtract(photo)
        XCTAssertEqual(store.bytes(root, .allocated), 12288)
        XCTAssertEqual(store.bytes(pictures, .allocated), 0)
        XCTAssertFalse(store.children(of: pictures).contains(photo))
    }

    func testLowerBoundBubblesFromInaccessibleChild() {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        let blocked = store.addNode(
            parent: root,
            name: "Mail",
            allocBytes: 0,
            logicalBytes: 0,
            kind: .other,
            flags: [.directory, .inaccessible, .lowerBound]
        )
        _ = blocked
        store.recomputeAll()
        XCTAssertTrue(store.flags(root).contains(.lowerBound))
    }

    func testHardLinkCountsOnce() {
        let rootPath = "/volumes/test"
        let listing = MapListing(map: [
            rootPath: .entries([
                ListedEntry(name: "a.bin", allocBytes: 8192, logicalBytes: 8192, linkCount: 2, device: 4, fileID: 99),
                ListedEntry(name: "b.bin", allocBytes: 8192, logicalBytes: 8192, linkCount: 2, device: 4, fileID: 99),
                ListedEntry(name: "c.bin", allocBytes: 4096, logicalBytes: 4096, linkCount: 1, device: 4, fileID: 100)
            ])
        ])
        let engine = ScanEngine(workerCount: 1)
        let store = engine.scan(rootPath: rootPath, displayName: "Test", lister: listing, rootDevice: 4)
        XCTAssertEqual(store.bytes(store.rootID, .allocated), 12288)
        let names = Set(store.children(of: store.rootID).map { store.name(of: $0) })
        XCTAssertEqual(names, ["a.bin", "b.bin", "c.bin"])
        let duplicate = store.children(of: store.rootID).first { store.flags($0).contains(.hardLinkDuplicate) }
        XCTAssertNotNil(duplicate)
        XCTAssertEqual(store.bytes(duplicate!, .allocated), 0)
    }

    func testInaccessibleDirectoryIncrementsCount() {
        let rootPath = "/volumes/test"
        let listing = MapListing(map: [
            rootPath: .entries([
                ListedEntry(name: "Secret", isDirectory: true)
            ]),
            rootPath + "/Secret": .inaccessible
        ])
        let engine = ScanEngine(workerCount: 1)
        let store = engine.scan(rootPath: rootPath, displayName: "Test", lister: listing, rootDevice: 1)
        let stats = engine.statistics()
        XCTAssertGreaterThanOrEqual(stats.inaccessible, 1)
        XCTAssertTrue(store.flags(store.rootID).contains(.lowerBound))
    }

    func testParallelScanMatchesSerialTotals() {
        let root = "/synth"
        let listing = SyntheticListing(rootPath: root, directories: 30, filesPerDirectory: 80)
        let serial = ScanEngine(workerCount: 1)
        let serialStore = serial.scan(rootPath: root, displayName: "S", lister: listing, rootDevice: 1)
        let parallel = ScanEngine(workerCount: 4)
        let parallelStore = parallel.scan(rootPath: root, displayName: "S", lister: listing, rootDevice: 1)
        XCTAssertEqual(serial.statistics().items, parallel.statistics().items)
        XCTAssertEqual(serialStore.bytes(serialStore.rootID, .allocated), parallelStore.bytes(parallelStore.rootID, .allocated))
        XCTAssertEqual(serialStore.nodeCount, parallelStore.nodeCount)
        XCTAssertEqual(serialStore.itemCount[Int(serialStore.rootID)], parallelStore.itemCount[Int(parallelStore.rootID)])
    }
}

final class SquarifyTests: XCTestCase {
    func testAreaProportionalNoOverlapDeterministic() {
        let items = [
            Squarify.Item(id: 1, weight: 6),
            Squarify.Item(id: 2, weight: 6),
            Squarify.Item(id: 3, weight: 4),
            Squarify.Item(id: 4, weight: 3),
            Squarify.Item(id: 5, weight: 2),
            Squarify.Item(id: 6, weight: 2),
            Squarify.Item(id: 7, weight: 1)
        ]
        let width = 100.0
        let height = 60.0
        let first = Squarify.layout(items: items, x: 0, y: 0, width: width, height: height, gap: 0)
        let second = Squarify.layout(items: items.shuffled(), x: 0, y: 0, width: width, height: height, gap: 0)
        XCTAssertEqual(first, second, "layout depends on weight and id, not input order")

        let canvas = width * height
        let totalWeight = items.reduce(0.0) { $0 + $1.weight }
        var covered = 0.0
        for box in first {
            covered += box.area
            let weight = items.first { $0.id == box.id }!.weight
            let error = abs(box.area / canvas - weight / totalWeight)
            XCTAssertLessThanOrEqual(error, 0.005, "id \(box.id) area error \(error)")
        }
        XCTAssertEqual(covered, canvas, accuracy: 0.01)
        assertNoOverlap(first)

        let aspects = first.map { max($0.width, $0.height) / max(1e-9, min($0.width, $0.height)) }
        XCTAssertLessThan(aspects.max() ?? 0, 50, "worst aspect stayed bounded for this set")
    }

    func testEqualWeightsKeepIdOrder() {
        let items = [
            Squarify.Item(id: 3, weight: 5),
            Squarify.Item(id: 1, weight: 5),
            Squarify.Item(id: 2, weight: 5)
        ]
        let boxes = Squarify.layout(items: items, x: 0, y: 0, width: 90, height: 30, gap: 0)
        XCTAssertEqual(boxes.map(\.id), [1, 2, 3])
        assertNoOverlap(boxes)
    }

    func testGapSeparatesNeighbours() {
        let boxes = Squarify.layout(
            items: [Squarify.Item(id: 1, weight: 1), Squarify.Item(id: 2, weight: 1)],
            x: 0, y: 0, width: 100, height: 40, gap: 2
        )
        XCTAssertEqual(boxes.count, 2)
        let ordered = boxes.sorted { $0.x < $1.x }
        let gap = ordered[1].x - (ordered[0].x + ordered[0].width)
        XCTAssertEqual(gap, 2, accuracy: 0.05)
        assertNoOverlap(boxes)
    }

    func testGapDoesNotOverlap() {
        let items = (1...12).map { Squarify.Item(id: UInt32($0), weight: Double($0)) }
        let boxes = Squarify.layout(items: items, x: 0, y: 0, width: 200, height: 120, gap: 2)
        assertNoOverlap(boxes)
    }

    private func assertNoOverlap(_ boxes: [LayoutBox], file: StaticString = #filePath, line: UInt = #line) {
        for i in boxes.indices {
            for j in boxes.indices where j > i {
                let a = boxes[i]
                let b = boxes[j]
                let overlapW = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let overlapH = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                let area = max(0, overlapW) * max(0, overlapH)
                XCTAssertLessThan(area, 0.01, "overlap \(a.id) \(b.id)", file: file, line: line)
            }
        }
    }
}

final class TileRuleTests: XCTestCase {
    func testTinySiblingsFoldAndNoSliversRemain() {
        var items = [Squarify.Item(id: 1, weight: 10_000)]
        items += (2...40).map { Squarify.Item(id: UInt32($0), weight: 1) }
        let prepared = TileFold.prepare(items, width: 240, height: 160, minimumExtent: 4, parent: 7)
        XCTAssertFalse(prepared.contains { $0.id == 2 })
        XCTAssertTrue(prepared.contains { TileFold.isRemainder($0.id) })
        let laid = Squarify.layout(items: prepared, x: 0, y: 0, width: 240, height: 160, gap: 2)
        let boxes = TileFold.absorbSlivers(laid, minimumExtent: 4)
        for box in boxes {
            XCTAssertGreaterThanOrEqual(box.width, 4, "id \(box.id) width \(box.width)")
            XCTAssertGreaterThanOrEqual(box.height, 4, "id \(box.id) height \(box.height)")
        }
    }

    func testSliverIsAbsorbedByTheTileItTouches() {
        let boxes = [
            LayoutBox(id: 1, x: 0, y: 0, width: 80, height: 40),
            LayoutBox(id: 2, x: 0, y: 40, width: 80, height: 2)
        ]
        let absorbed = TileFold.absorbSlivers(boxes, minimumExtent: 4)
        XCTAssertEqual(absorbed.count, 1)
        XCTAssertEqual(absorbed[0].height, 42, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(absorbed[0].width, 4)
        XCTAssertGreaterThanOrEqual(absorbed[0].height, 4)
    }

    func testLabelSitsInsideTheTileAndHidesWhenCramped() {
        let frame = LabelPlacement.frame(tileX: 10, tileY: 20, tileWidth: 90, tileHeight: 48, header: 0)
        XCTAssertTrue(frame.visible)
        XCTAssertGreaterThanOrEqual(frame.x, 10)
        XCTAssertGreaterThanOrEqual(frame.y, 20)
        XCTAssertLessThanOrEqual(frame.x + frame.width, 100)
        XCTAssertLessThanOrEqual(frame.y + frame.height, 68)
        let hidden = LabelPlacement.frame(tileX: 0, tileY: 0, tileWidth: 20, tileHeight: 10, header: 0)
        XCTAssertFalse(hidden.visible)
        let header = LabelPlacement.frame(tileX: 0, tileY: 0, tileWidth: 120, tileHeight: 80, header: 19)
        XCTAssertTrue(header.visible)
        XCTAssertEqual(header.y, 1, accuracy: 0.01)
        XCTAssertLessThanOrEqual(header.height, 19)
    }
}

final class HitTestTests: XCTestCase {
    func testHitsDeepestNodeAndHeader() {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        let docs = store.addNode(parent: root, name: "Documents", allocBytes: 0, logicalBytes: 0, kind: .documents, flags: .directory)
        _ = store.addNode(parent: docs, name: "Notes.pdf", allocBytes: 40_000_000_000, logicalBytes: 40_000_000_000, kind: .documents, flags: [])
        _ = store.addNode(parent: root, name: "Movie.mov", allocBytes: 10_000_000_000, logicalBytes: 10_000_000_000, kind: .media, flags: [])
        store.recomputeAll()
        let layout = TreemapLayout.build(store: store, rootID: root, width: 400, height: 300, options: TreemapOptions(gap: 0, maxHeaderDepth: 4))
        guard let docsNode = layout.nodes.first(where: { $0.id == docs && $0.depth == 1 }) else {
            return XCTFail("missing documents tile")
        }
        if docsNode.header > 0 {
            let headerHit = HitTest.hit(layout, x: docsNode.x + 4, y: docsNode.y + 2)
            XCTAssertEqual(headerHit, docs)
        }
        let kids = layout.children(of: layout.nodes.firstIndex(where: { $0.id == docs && $0.depth == 1 }) ?? 0)
        XCTAssertFalse(kids.isEmpty)
        let childIndex = kids[kids.startIndex]
        let child = layout.nodes[childIndex]
        let hit = HitTest.hit(layout, x: child.x + child.width / 2, y: child.y + child.height / 2)
        XCTAssertEqual(hit, child.id)
        XCTAssertEqual(store.name(of: child.id), "Notes.pdf")
        XCTAssertNil(HitTest.hit(layout, x: -5, y: -5))
    }
}

final class LayoutPolicyTests: XCTestCase {
    func testVisibleDepthIsCappedAtTwoAndCanReachThree() {
        let store = branchedStore()
        let shallow = TreemapLayout.build(
            store: store.store, rootID: store.root, width: 800, height: 600,
            options: TreemapOptions(gap: 0, maxVisibleDepth: 2, minTileWidth: 40, minTileHeight: 24)
        )
        XCTAssertFalse(shallow.nodes.contains { $0.depth > 2 })
        XCTAssertTrue(shallow.nodes.contains { $0.id == store.mid && $0.isDepthCapped })
        XCTAssertFalse(shallow.nodes.contains { $0.id == store.deep })
        XCTAssertFalse(shallow.nodes.contains { $0.id == store.deeper })

        let deeper = TreemapLayout.build(
            store: store.store, rootID: store.root, width: 800, height: 600,
            options: TreemapOptions(gap: 0, maxVisibleDepth: 3, minTileWidth: 40, minTileHeight: 24)
        )
        XCTAssertFalse(deeper.nodes.contains { $0.depth > 3 })
        // deep has a single directory child, so the capped tile is that leaf, not another row of headers.
        XCTAssertTrue(deeper.nodes.contains { $0.id == store.deeper && $0.isDepthCapped && $0.headerTitle == "deep / deeper" })
        XCTAssertFalse(deeper.nodes.contains { $0.id == store.deep })
        XCTAssertFalse(deeper.nodes.contains { store.store.name(of: $0.id) == "x" })
        XCTAssertEqual(TreemapOptions(maxVisibleDepth: 9).maxVisibleDepth, 3)
        XCTAssertEqual(TreemapOptions(maxVisibleDepth: 0).maxVisibleDepth, 1)
    }

    func testTilesUnder40By24FoldIntoOneRemainder() {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        let folder = store.addNode(parent: root, name: "Photos", allocBytes: 0, logicalBytes: 0, kind: .photos, flags: .directory)
        _ = store.addNode(parent: folder, name: "huge", allocBytes: 80_000_000_000, logicalBytes: 80_000_000_000, kind: .photos, flags: [])
        for index in 0..<40 {
            _ = store.addNode(parent: folder, name: "tiny-\(index)", allocBytes: 4096, logicalBytes: 4096, kind: .photos, flags: [])
        }
        _ = store.addNode(parent: root, name: "other", allocBytes: 20_000_000_000, logicalBytes: 20_000_000_000, kind: .other, flags: [])
        store.recomputeAll()
        let layout = TreemapLayout.build(
            store: store, rootID: root, width: 900, height: 600,
            options: TreemapOptions(gap: 2, maxVisibleDepth: 2, minTileWidth: 40, minTileHeight: 24)
        )
        let names = layout.nodes.filter { $0.depth > 1 }.map(\.label)
        XCTAssertFalse(names.contains { $0.hasPrefix("tiny-") }, "tiny files stay inside the fold")
        let huge = layout.nodes.filter { $0.label == "huge" }
        XCTAssertEqual(huge.count, 1)
        XCTAssertGreaterThan(huge[0].width, 40)
        XCTAssertGreaterThan(huge[0].height, 24)
    }

    func testLabelsRequireTheFullNameAndSize() {
        XCTAssertFalse(LabelFit.fits(name: "Application Support", sizeText: "12.4 GB", tileWidth: 52, tileHeight: 28, header: 0))
        XCTAssertTrue(LabelFit.fits(name: "Mail", sizeText: "4.2 GB", tileWidth: 220, tileHeight: 80, header: 0))
        XCTAssertTrue(LabelFit.fits(name: "Users / jxzheng / Library", sizeText: "52.3 GB", tileWidth: 520, tileHeight: 90, header: 19))
        XCTAssertFalse(LabelFit.fits(name: "Users / jxzheng / Library", sizeText: "52.3 GB", tileWidth: 80, tileHeight: 40, header: 19))

        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        for index in 0..<6 {
            _ = store.addNode(
                parent: root,
                name: "Application Support \(index)",
                allocBytes: 8_000_000_000,
                logicalBytes: 8_000_000_000,
                kind: .other,
                flags: []
            )
        }
        store.recomputeAll()
        let layout = TreemapLayout.build(
            store: store, rootID: root, width: 180, height: 80,
            options: TreemapOptions(gap: 2, maxVisibleDepth: 2, minTileWidth: 20, minTileHeight: 16)
        )
        for tile in layout.nodes where tile.depth > 0 && tile.showsLabel {
            XCTAssertTrue(LabelFit.fits(
                name: tile.label,
                sizeText: ByteFormat.bytes(tile.sizeBytes),
                tileWidth: tile.width,
                tileHeight: tile.height,
                header: 0
            ))
            XCTAssertFalse(tile.label.contains("…"))
        }
        XCTAssertFalse(layout.nodes.contains { $0.showsLabel && $0.label.contains("Application Support") })
    }

    func testSingleChildChainsCollapseToABreadcrumb() {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        let users = store.addNode(parent: root, name: "Users", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        let person = store.addNode(parent: users, name: "jxzheng", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        let library = store.addNode(parent: person, name: "Library", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        _ = store.addNode(parent: library, name: "Mail", allocBytes: 30_000_000_000, logicalBytes: 30_000_000_000, kind: .other, flags: [])
        _ = store.addNode(parent: library, name: "Messages", allocBytes: 22_000_000_000, logicalBytes: 22_000_000_000, kind: .caches, flags: [])
        _ = store.addNode(parent: root, name: "Applications", allocBytes: 12_000_000_000, logicalBytes: 12_000_000_000, kind: .apps, flags: [])
        store.recomputeAll()
        let layout = TreemapLayout.build(
            store: store, rootID: root, width: 800, height: 500,
            options: TreemapOptions(gap: 0, maxVisibleDepth: 2, minTileWidth: 40, minTileHeight: 24)
        )
        let chain = layout.nodes.filter { $0.headerTitle == "Users / jxzheng / Library" }
        XCTAssertEqual(chain.count, 1)
        XCTAssertEqual(chain[0].id, library)
        XCTAssertEqual(chain[0].depth, 1)
        XCTAssertFalse(layout.nodes.contains { $0.id == users })
        XCTAssertFalse(layout.nodes.contains { $0.id == person })
        let children = layout.children(of: layout.nodes.firstIndex(where: { $0.id == library }) ?? 0)
        XCTAssertEqual(children.count, 2)
    }

    func testTileAreaMatchesBytesIncludingFolds() {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        _ = store.addNode(parent: root, name: "Users", allocBytes: 50_000_000_000, logicalBytes: 50_000_000_000, kind: .other, flags: [])
        _ = store.addNode(parent: root, name: "Applications", allocBytes: 30_000_000_000, logicalBytes: 30_000_000_000, kind: .apps, flags: [])
        for index in 0..<40 {
            _ = store.addNode(parent: root, name: "tiny-\(index)", allocBytes: 20_000_000, logicalBytes: 20_000_000, kind: .other, flags: [])
        }
        store.recomputeAll()
        let layout = TreemapLayout.build(
            store: store, rootID: root, width: 1000, height: 600,
            options: TreemapOptions(gap: 0, maxVisibleDepth: 1, minTileWidth: 40, minTileHeight: 24, maxTiles: 60)
        )
        let rootArea = 1000.0 * 600.0
        let rootBytes = Double(layout.nodes[layout.root].sizeBytes)
        XCTAssertGreaterThan(rootBytes, 0)
        let tiles = layout.nodes.filter { $0.depth > 0 }
        XCTAssertLessThanOrEqual(tiles.count, 60)
        XCTAssertFalse(tiles.contains { $0.label.hasPrefix("tiny-") })
        if let remainder = tiles.first(where: \.isRemainder) {
            XCTAssertGreaterThanOrEqual(remainder.foldedCount, 40)
        }
        for tile in tiles {
            let areaFraction = (tile.width * tile.height) / rootArea
            let byteFraction = Double(tile.sizeBytes) / rootBytes
            XCTAssertEqual(areaFraction, byteFraction, accuracy: 0.01, "\(tile.label) area \(areaFraction) bytes \(byteFraction)")
            XCTAssertFalse(tile.label.isEmpty, "unnamed tile")
        }
    }

    func testMessyViewShowsAtMostSixtyNamedTiles() {
        var store = NodeStore()
        let root = store.addRoot(name: "home")
        let users = store.addNode(parent: root, name: "Users", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        let person = store.addNode(parent: users, name: "person", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        let library = store.addNode(parent: person, name: "Library", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        for index in 0..<180 {
            let bytes = UInt64(index + 1) * 8_000_000
            _ = store.addNode(parent: library, name: "item-\(index)", allocBytes: bytes, logicalBytes: bytes, kind: .other, flags: [])
        }
        _ = store.addNode(parent: root, name: "Applications", allocBytes: 4_000_000_000, logicalBytes: 4_000_000_000, kind: .apps, flags: [])
        store.recomputeAll()
        let layout = TreemapLayout.build(
            store: store, rootID: root, width: 1200, height: 800,
            options: .browsing(metric: .allocated, zoomed: false)
        )
        let tiles = layout.nodes.filter { $0.depth > 0 }
        XCTAssertLessThanOrEqual(tiles.count, 60, "visible \(tiles.count)")
        XCTAssertFalse(tiles.isEmpty)
        for tile in tiles {
            XCTAssertFalse(tile.label.isEmpty, "unnamed tile id \(tile.id)")
            XCTAssertFalse(tile.label.contains("…"))
        }
        XCTAssertTrue(tiles.contains { $0.headerTitle.contains("Users / person / Library") || $0.label.contains("Users / person / Library") })
        XCTAssertFalse(tiles.contains { $0.header > 0 }, "header bars belong in the top breadcrumb, not the map")
    }

    func testSpatialIndexMatchesTheSmallestContainingTile() {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        let docs = store.addNode(parent: root, name: "Documents", allocBytes: 0, logicalBytes: 0, kind: .documents, flags: .directory)
        let notes = store.addNode(parent: docs, name: "Notes.pdf", allocBytes: 40_000_000_000, logicalBytes: 40_000_000_000, kind: .documents, flags: [])
        let movie = store.addNode(parent: root, name: "Movie.mov", allocBytes: 10_000_000_000, logicalBytes: 10_000_000_000, kind: .media, flags: [])
        store.recomputeAll()
        let layout = TreemapLayout.build(
            store: store, rootID: root, width: 400, height: 300,
            options: TreemapOptions(gap: 0, maxHeaderDepth: 4, maxVisibleDepth: 2)
        )
        XCTAssertGreaterThan(layout.index.columns, 0)
        for gy in 0..<24 {
            for gx in 0..<32 {
                let x = (Double(gx) + 0.5) / 32 * 400
                let y = (Double(gy) + 0.5) / 24 * 300
                XCTAssertEqual(HitTest.hit(layout, x: x, y: y), brute(layout, x, y), "at \(x), \(y)")
            }
        }
        if let notesNode = layout.nodes.first(where: { $0.id == notes }) {
            let hit = HitTest.hit(layout, x: notesNode.x + notesNode.width / 2, y: notesNode.y + notesNode.height / 2)
            XCTAssertEqual(hit, notes)
        } else {
            XCTFail("notes tile missing")
        }
        XCTAssertNotNil(layout.nodes.first { $0.id == movie })
        XCTAssertNil(HitTest.hit(layout, x: -4, y: 10))
        XCTAssertNil(HitTest.hit(layout, x: 10, y: 400))
    }

    private func brute(_ layout: TreemapLayout, _ x: Double, _ y: Double) -> UInt32? {
        guard layout.nodes.indices.contains(layout.root), layout.nodes[layout.root].contains(x, y) else { return nil }
        var best = layout.root
        var bestArea = layout.nodes[layout.root].width * layout.nodes[layout.root].height
        for index in layout.nodes.indices where index != layout.root {
            let node = layout.nodes[index]
            guard node.contains(x, y) else { continue }
            let area = node.width * node.height
            if area < bestArea || (area == bestArea && node.depth > layout.nodes[best].depth) {
                bestArea = area
                best = index
            }
        }
        return layout.nodes[best].id
    }

    private struct Branched {
        var store: NodeStore
        var root: UInt32
        var mid: UInt32
        var deep: UInt32
        var deeper: UInt32
    }

    private func branchedStore() -> Branched {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        let top = store.addNode(parent: root, name: "top", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        let mid = store.addNode(parent: top, name: "mid", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        let deep = store.addNode(parent: mid, name: "deep", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        let deeper = store.addNode(parent: deep, name: "deeper", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        _ = store.addNode(parent: deeper, name: "x", allocBytes: 30_000_000_000, logicalBytes: 30_000_000_000, kind: .other, flags: [])
        _ = store.addNode(parent: top, name: "sibling", allocBytes: 20_000_000_000, logicalBytes: 20_000_000_000, kind: .other, flags: [])
        _ = store.addNode(parent: mid, name: "side", allocBytes: 12_000_000_000, logicalBytes: 12_000_000_000, kind: .other, flags: [])
        _ = store.addNode(parent: root, name: "other", allocBytes: 8_000_000_000, logicalBytes: 8_000_000_000, kind: .other, flags: [])
        store.recomputeAll()
        return Branched(store: store, root: root, mid: mid, deep: deep, deeper: deeper)
    }
}

final class POSIXScanTests: XCTestCase {
    func testDoesNotFollowSymlinksAndSumsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quadrat-posix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try Data(repeating: 7, count: 5000).write(to: file)
        let sub = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: sub.appendingPathComponent("a.txt"))
        let link = root.appendingPathComponent("jump")
        symlink(sub.path, link.path)
        let engine = ScanEngine(workerCount: 2)
        let store = engine.scan(
            rootPath: root.path,
            displayName: "tmp",
            lister: POSIXListing(),
            rootDevice: PathDevice.device(of: root.path)
        )
        let names = Set(store.children(of: store.rootID).map { store.name(of: $0) })
        XCTAssertTrue(names.contains("notes.txt"))
        XCTAssertTrue(names.contains("nested"))
        XCTAssertTrue(names.contains("jump"))
        let linkNode = store.children(of: store.rootID).first { store.name(of: $0) == "jump" }
        XCTAssertTrue(store.flags(linkNode!).contains(.symlink))
        XCTAssertTrue(store.children(of: linkNode!).isEmpty, "symlinks are not walked")
        XCTAssertGreaterThan(store.bytes(store.rootID, .logical), 0)
        XCTAssertEqual(engine.statistics().inaccessible, 0)
    }
}

final class ReadableTileTests: XCTestCase {
    func testMessyFixtureTilesAllHaveFittingLabels() {
        let store = wideFolder(named: "Library", count: 180)
        assertEveryTileIsLabelled(store)
    }

    func testVolumeFixtureTilesAllHaveFittingLabels() {
        var store = NodeStore()
        let root = store.addRoot(name: "Macintosh HD")
        let system = store.addNode(parent: root, name: "System", allocBytes: 0, logicalBytes: 0, kind: .system, flags: .directory)
        let library = store.addNode(parent: system, name: "Library", allocBytes: 0, logicalBytes: 0, kind: .system, flags: .directory)
        for name in ["Extensions", "Frameworks", "AssetsV2", "Caches"] {
            _ = store.addNode(parent: library, name: name, allocBytes: 8_000_000_000, logicalBytes: 8_000_000_000, kind: .system, flags: .directory)
        }
        let users = store.addNode(parent: root, name: "Users", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        let you = store.addNode(parent: users, name: "you", allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        for name in ["Documents", "Pictures", "Library", "Downloads"] {
            _ = store.addNode(parent: you, name: name, allocBytes: 12_000_000_000, logicalBytes: 12_000_000_000, kind: .documents, flags: [])
        }
        _ = store.addNode(parent: root, name: "Applications", allocBytes: 20_000_000_000, logicalBytes: 20_000_000_000, kind: .apps, flags: .directory)
        store.recomputeAll()
        assertEveryTileIsLabelled(store)
    }

    func testFolderShareStaysInsideTheDisk() {
        let share = DiskShare(capacity: 1_000_000_000_000, free: 800_000_000_000, volumeName: "Macintosh HD")
        XCTAssertGreaterThan(share.capacity, 0)
        let percent = share.percent(of: 50_000_000_000)
        XCTAssertGreaterThanOrEqual(percent, 0)
        XCTAssertLessThanOrEqual(percent, 100)
        XCTAssertEqual(percent, 5, accuracy: 0.01)
        XCTAssertEqual(DiskShare.percent(50_000_000_000, of: 0), 0)
    }

    func testBreadcrumbDropsRepeatedFirmlinkSegments() {
        XCTAssertEqual(
            BreadcrumbLine.line(from: ["Macintosh HD", "Macintosh HD / Users / you"]),
            "Macintosh HD / Users / you"
        )
        XCTAssertEqual(
            BreadcrumbLine.line(from: ["Macintosh HD", "System", "System / Library"]),
            "Macintosh HD / System / Library"
        )
        XCTAssertEqual(
            BreadcrumbLine.segments(from: ["/System/Volumes/Data/Users/you"]),
            ["Users", "you"]
        )
    }

    private func wideFolder(named: String, count: Int) -> NodeStore {
        var store = NodeStore()
        let root = store.addRoot(name: "disk")
        let folder = store.addNode(parent: root, name: named, allocBytes: 0, logicalBytes: 0, kind: .other, flags: .directory)
        for index in 0..<count {
            let bytes = UInt64(index + 1) * 4_000_000
            _ = store.addNode(parent: folder, name: "item-\(index)", allocBytes: bytes, logicalBytes: bytes, kind: .other, flags: [])
        }
        _ = store.addNode(parent: root, name: "Applications", allocBytes: 6_000_000_000, logicalBytes: 6_000_000_000, kind: .apps, flags: [])
        store.recomputeAll()
        return store
    }

    private func assertEveryTileIsLabelled(_ store: NodeStore, file: StaticString = #filePath, line: UInt = #line) {
        let report = LayoutAudit.check(store: store)
        XCTAssertGreaterThan(report.tiles, 0, file: file, line: line)
        XCTAssertEqual(report.unlabeled, 0, "unlabeled \(report.unlabeled) of \(report.tiles)", file: file, line: line)
    }
}

final class MemoryTests: XCTestCase {
    func testFoldedSyntheticTreeStaysCompact() {
        let root = "/synth"
        let directories = 5_000
        let files = 300
        let listing = SyntheticListing(rootPath: root, directories: directories, filesPerDirectory: files)
        XCTAssertGreaterThanOrEqual(listing.fileCount, 1_500_000)
        let engine = ScanEngine(workerCount: 4)
        let store = engine.scan(rootPath: root, displayName: "Synth", lister: listing, rootDevice: 1)
        let stats = engine.statistics()
        XCTAssertGreaterThanOrEqual(stats.items, 1_500_000)
        XCTAssertEqual(store.nodeCount, 1 + directories * 34)
        XCTAssertLessThan(store.estimatedPayloadBytes, 40_000_000)
        let bench = LayoutBench.measure(store: store, hoverSamples: 80, zoomSamples: 8)
        XCTAssertLessThan(bench.hoverP99Ms, 16)
        XCTAssertLessThan(bench.zoomP99Ms, 16)
    }

    func testMacShapedTreeStaysUnderMemoryBudget() {
        let listing = MacShapedListing(rootPath: "/mac")
        XCTAssertGreaterThanOrEqual(listing.directoryCount, 1_000_000)
        XCTAssertGreaterThanOrEqual(listing.fileCount + listing.directoryCount, 3_800_000)
        let engine = ScanEngine(workerCount: 4)
        let store = engine.scan(rootPath: "/mac", displayName: "Macintosh HD", lister: listing, rootDevice: 1)
        let stats = engine.statistics()
        XCTAssertGreaterThanOrEqual(stats.items, 3_800_000)
        XCTAssertGreaterThanOrEqual(stats.directories, 900_000)
        XCTAssertLessThan(store.liveNodeCount, 250_000, "folding should drop the million directories")
        XCTAssertLessThan(store.estimatedPayloadBytes, 60_000_000, "model \(store.estimatedPayloadBytes) bytes")
        // The previous / scan peaked at 781 MB with 2.17M retained nodes.
        // AppKit plus the Swift runtime sat around 40 MB once the name table was not a dictionary of every filename.
        let projectedPeakRSS = store.estimatedPayloadBytes + 40_000_000
        XCTAssertLessThan(projectedPeakRSS, 100_000_000, "projected RSS \(projectedPeakRSS)")
        XCTAssertGreaterThan(store.bytes(store.rootID, .allocated), 1 << 30)
        print("mac-shaped live=\(store.liveNodeCount) slots=\(store.nodeCount) payload=\(store.estimatedPayloadBytes) items=\(stats.items) dirs=\(stats.directories) projected=\(projectedPeakRSS)")
    }
}

final class KindTests: XCTestCase {
    func testClassifierPrefersSpecificNamesOverParent() {
        XCTAssertEqual(KindClassifier.classify(name: "node_modules", parent: .developer, isDirectory: true), .nodeModules)
        XCTAssertEqual(KindClassifier.classify(name: "Docker.raw", parent: .developer, isDirectory: false), .vms)
        XCTAssertEqual(KindClassifier.classify(name: "DerivedData", parent: .developer, isDirectory: true), .builds)
        XCTAssertEqual(KindClassifier.classify(name: "shot.JPG", parent: .other, isDirectory: false), .photos)
        XCTAssertEqual(KindClassifier.classify(name: "IMG_1.heic", parent: .documents, isDirectory: false), .photos)
        XCTAssertEqual(KindClassifier.classify(name: "notes.txt", parent: .documents, isDirectory: false), .documents)
    }
}
