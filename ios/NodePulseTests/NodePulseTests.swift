import XCTest
import SwiftUI
import CryptoKit
import Network
@testable import NodePulse

final class NodePulseTests: XCTestCase {
    @MainActor func testEditedRelayRetriesHistoryWithoutPollingRestart() async throws {
        let legacy = try HistoryRelayFixture(legacy: true), modern = try HistoryRelayFixture(legacy: false)
        defer { legacy.stop(); modern.stop() }
        let ready = expectation(description: "relay listeners ready"); ready.expectedFulfillmentCount = 2
        legacy.start { ready.fulfill() }; modern.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        let suite = "RelayEdit-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, secrets: MemorySecrets())
        var endpoint = Endpoint(name: "legacy", kind: .groupTCP(host: "127.0.0.1", port: legacy.port))
        try store.save(endpoint, secret: "token", groupSecret: "group")
        await store.refresh(); await store.refresh()
        XCTAssertEqual(legacy.historyRequests, [true, false, false])
        endpoint.name = "renamed"
        try store.save(endpoint, secret: "token", groupSecret: "group")
        await store.refresh()
        XCTAssertEqual(legacy.historyRequests, [true, false, false, false])
        XCTAssertThrowsError(try store.save(endpoint, secret: "token", groupSecret: ""))
        await store.refresh()
        XCTAssertEqual(legacy.historyRequests, [true, false, false, false, false])
        endpoint.kind = .groupTCP(host: "127.0.0.1", port: modern.port)
        try store.save(endpoint, secret: "token", groupSecret: "group")
        await store.refresh()
        XCTAssertEqual(modern.historyRequests, [true])
        XCTAssertNil(store.statuses[endpoint.id]?.error)
        print("Edited relay history request flags: \(modern.historyRequests)")
    }
    private func historyBatch(_ numbers: [UInt32], full: Bool = true, epoch: String = "1234567890abcdef",
                              latest: UInt32? = nil) -> HistoryBatch {
        HistoryBatch(epoch: epoch, seq: latest ?? numbers.last ?? 0, full: full,
                     samples: numbers.enumerated().map { offset, seq in
                         [Double(seq), 1000 + Double(offset), 10, 20, 0, 30, 1, 2, 3, 40, 50]
                     })
    }
    func testHistoryMergeDedupRetentionAndWrap() throws {
        var window = HistoryWindow()
        XCTAssertTrue(window.merge(historyBatch(Array(1...120))))
        XCTAssertEqual(window.samples.count, 120)
        var increment = historyBatch([120, 121, 122], full: false)
        for index in increment.samples.indices { increment.samples[index][1] = 1119 + Double(index) }
        XCTAssertTrue(window.merge(increment))
        XCTAssertEqual(window.samples.count, 120)
        XCTAssertEqual(window.samples.first?.seq, 3)
        XCTAssertTrue(window.merge(increment))
        XCTAssertEqual(window.samples.count, 120)
        XCTAssertEqual(window.cursor?.since, 122)
        XCTAssertEqual(window.samples.map(\.date), window.samples.map(\.date).sorted())
        XCTAssertTrue(window.merge(historyBatch([UInt32.max - 1, UInt32.max, 0, 1], epoch: "abcdef1234567890")))
        XCTAssertEqual(window.samples.map(\.seq), [UInt32.max - 1, UInt32.max, 0, 1])
        var skewed = historyBatch([2, 3, 4], epoch: "abcdef1234567890")
        skewed.samples[1][1] = 999
        XCTAssertTrue(window.merge(skewed))
        XCTAssertEqual(window.samples.map(\.date), window.samples.map(\.date).sorted())
    }
    func testHistoryGapEpochMalformedAndEmptyRecovery() throws {
        var window = HistoryWindow()
        XCTAssertTrue(window.merge(historyBatch([1, 2])))
        XCTAssertTrue(window.merge(historyBatch([], full: false, latest: 2)))
        XCTAssertFalse(window.merge(historyBatch([4], full: false)))
        XCTAssertNil(window.cursor)
        XCTAssertEqual(window.samples.count, 2)
        XCTAssertTrue(window.merge(historyBatch([1, 2, 4])))
        XCTAssertFalse(window.merge(historyBatch([5], full: false, epoch: "abcdef1234567890")))
        XCTAssertNil(window.cursor)
        XCTAssertTrue(window.merge(historyBatch([1], epoch: "abcdef1234567890")))
        var bad = historyBatch([2], full: false, epoch: "abcdef1234567890")
        bad.samples[0].removeLast()
        XCTAssertFalse(window.merge(bad))
        XCTAssertNil(window.cursor)
        XCTAssertTrue(window.merge(historyBatch([])))
        XCTAssertTrue(window.samples.isEmpty)
        XCTAssertThrowsError(try historyBatch([1, 1]).points())
        XCTAssertThrowsError(try historyBatch([1], epoch: "invalid").points())
    }
    @MainActor func testHistoryForegroundReconnectAndLegacyRules() throws {
        let suite = "History-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, secrets: MemorySecrets())
        XCTAssertEqual(store.refreshInterval, 1)
        let endpoint = Endpoint(name: "test", kind: .direct(host: "localhost", port: 9000))
        var node = NodeSnapshot(); node.id = "node"
        store.apply(endpoint, result: .success([node]), latency: 1, histories: [node.id: historyBatch([1, 2])])
        XCTAssertEqual(store.nodes.first?.historyWindow.cursor?.since, 2)
        store.start()
        XCTAssertNil(store.nodes.first?.historyWindow.cursor)
        store.stop()
        store.apply(endpoint, result: .success([node]), latency: 1, histories: [node.id: historyBatch([3, 4])])
        store.apply(endpoint, result: .failure(ProbeError.refused), latency: 1)
        XCTAssertNil(store.nodes.first?.historyWindow.cursor)
        store.apply(endpoint, result: .success([node]), latency: 1)
        XCTAssertNil(store.nodes.first?.historyWindow.cursor)
        XCTAssertNil(store.nodes.first?.history.last?.seq)
        store.start(); store.stop()
        XCTAssertNil(store.nodes.first?.historyWindow.cursor)
    }
    func testHistoryRelayDomainBindingAndSignedCursor() throws {
        let group = try GroupCrypto(secret: "history-test")
        let slot = group.slot(for: "node"), epoch = "1234567890abcdef", seq: UInt32 = 1
        let row = historyBatch([seq]).samples[0]
        let plain = try JSONSerialization.data(withJSONObject: ["epoch": epoch, "sample": row])
        let ad = Data("npulse-history-v1:\(group.gid):\(slot):\(epoch):\(seq)".utf8)
        let sealed = try ChaChaPoly.seal(plain, using: group.encKey, authenticating: ad).combined.base64EncodedString()
        var object: [String: Any] = ["epoch": epoch, "seq": seq, "full": true, "samples": [[seq, sealed]]]
        XCTAssertEqual(try group.openHistory(object, slot: slot).samples, [row])
        object["samples"] = [[2, sealed]]
        XCTAssertThrowsError(try group.openHistory(object, slot: slot))
        object["samples"] = [[seq, sealed]]
        XCTAssertThrowsError(try group.openHistory(object, slot: String(repeating: "0", count: 32)))
        object["epoch"] = "abcdef1234567890"
        XCTAssertThrowsError(try group.openHistory(object, slot: slot))
        let request = try group.getRequest(timestamp: 123, requestID: String(repeating: "a", count: 32),
                                           since: [slot: HistoryCursor(epoch: epoch, since: seq)])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.json) as? [String: Any])
        let map = try JSONSerialization.data(withJSONObject: json["since"]!, options: [.sortedKeys, .withoutEscapingSlashes])
        let message = Data("npulse-gget\n\(group.gid)\n123\n\(request.rid)\n".utf8) + map
        let hex = try XCTUnwrap(json["sig"] as? String)
        let signature = Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
        XCTAssertTrue(group.signingKey.publicKey.isValidSignature(signature, for: message))
        XCTAssertFalse(group.signingKey.publicKey.isValidSignature(signature, for: message + Data(" ".utf8)))
        let legacy = try group.getRequest(timestamp: 123, requestID: request.rid)
        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.json) as? [String: Any])
        XCTAssertNil(legacyJSON["since"])
        print("HISTORY_APP_REQUEST \(request.json.base64EncodedString())")
    }
    @MainActor func testCompactCardHeightIndependentOfBadgeLocationAndEmptyMetadata() throws {
        let suite = "Compact-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, secrets: MemorySecrets())
        for size in [DynamicTypeSize.large, .accessibility3] {
            var baseline: CGFloat?
            for encrypted in [false, true] {
                for address in [nil, "1.1.1.1", "invalid", "10.0.0.1"] as [String?] {
                    for empty in [false, true] {
                        let kind: Endpoint.Kind = encrypted ? .direct(host: "localhost", port: 9000) : .https(urlString: "https://example.com")
                        let endpoint = Endpoint(name: "test", kind: kind)
                        var snapshot = NodeSnapshot(); snapshot.id = "node"
                        snapshot.name = empty ? "" : "A long node name that truncates"
                        snapshot.os = empty ? "" : "OpenWrt 23.05"; snapshot.egressIp = address
                        store.apply(endpoint, result: .success([snapshot]), latency: 1)
                        if empty { store.apply(endpoint, result: .failure(ProbeError.timeout), latency: 1) }
                        let item = try XCTUnwrap(store.nodes.last)
                        let renderer = ImageRenderer(content: CompactNodeCard(item: item, locations: store.locations, demo: true)
                            .frame(width: 180).environment(\.dynamicTypeSize, size))
                        let height = try XCTUnwrap(renderer.uiImage).size.height
                        XCTAssertGreaterThan(height, 100)
                        if let baseline { XCTAssertEqual(height, baseline, accuracy: 1) }
                        else { baseline = height }
                    }
                }
            }
        }
    }

    @MainActor func testDetailHeaderAddressSelection() {
        XCTAssertEqual(DetailHeader.addresses(primary: "192.168.1.1", egress: "1.1.1.1"), ["192.168.1.1", "1.1.1.1"])
        XCTAssertEqual(DetailHeader.addresses(primary: "1.1.1.1", egress: "1.1.1.1"), ["1.1.1.1"])
        XCTAssertEqual(DetailHeader.addresses(primary: nil, egress: "1.1.1.1"), ["1.1.1.1"])
        XCTAssertEqual(DetailHeader.addresses(primary: nil, egress: nil), [])
        XCTAssertEqual(DetailHeader.addresses(primary: "", egress: "invalid"), [])
        XCTAssertEqual(DetailHeader.addresses(primary: "192.168.1.1", egress: "10.0.0.1"), ["192.168.1.1"])
        XCTAssertEqual(DetailHeader.addresses(primary: "2606:4700::ABCD", egress: "2606:4700::abcd").count, 1)
    }
    func testChartReadoutLatestSelectedAndEmpty() {
        let start = Date(timeIntervalSince1970: 1000)
        let history = (0..<3).map { HistorySample(date: start.addingTimeInterval(Double($0) * 5), cpu: Double($0), memPercent: 0, rxRate: 0, txRate: 0) }
        XCTAssertEqual(HistorySample.displayed(in: history, at: nil), history.last)
        XCTAssertEqual(HistorySample.displayed(in: history, at: start.addingTimeInterval(6)), history[1])
        XCTAssertEqual(HistorySample.displayed(in: history, at: start.addingTimeInterval(-100)), history.first)
        XCTAssertEqual(HistorySample.displayed(in: history, at: start.addingTimeInterval(100)), history.last)
        XCTAssertNil(HistorySample.displayed(in: [], at: nil))
        XCTAssertNil(HistorySample.displayed(in: [], at: start))
    }
    func testChartBufferRetainsClippedPredecessorAndFutureSample() {
        let origin = Date(timeIntervalSince1970: 1000)
        func points(_ range: ClosedRange<Int>) -> [HistorySample] {
            range.map { HistorySample(date: origin.addingTimeInterval(Double($0)), cpu: Double($0 % 100), memPercent: 20, rxRate: 30, txRate: 40, seq: UInt32($0)) }
        }
        var buffer = HistoryChartBuffer()
        for latest in 119...130 {
            let end = origin.addingTimeInterval(Double(latest - 1))
            buffer.observe(points((latest - 119)...latest), ending: end)
            XCTAssertEqual(buffer.samples.first?.seq, UInt32(max(0, latest - 122)))
            XCTAssertEqual(buffer.samples.last?.seq, UInt32(latest))
            XCTAssertLessThanOrEqual(buffer.samples.count, 123)
        }
        let originalID = buffer.samples.last!.chartID
        var correction = points(11...130)
        correction[119].cpu = 99
        buffer.observe(correction, ending: origin.addingTimeInterval(129))
        XCTAssertEqual(buffer.samples.last?.chartID, originalID)
        XCTAssertEqual(buffer.samples.last?.cpu, 99)
        XCTAssertEqual(buffer.samples.first?.seq, 8)
    }
    func testChartBufferReplacesAuthoritativeRangeAndCorrectedTimestamps() {
        let origin = Date(timeIntervalSince1970: 1000)
        let points = (1...4).map { HistorySample(date: origin.addingTimeInterval(Double($0)), cpu: 20, memPercent: 30, rxRate: 40, txRate: 50, seq: UInt32($0)) }
        var buffer = HistoryChartBuffer()
        buffer.observe(points, ending: origin)
        buffer.observe([points[0], points[2]], ending: origin)
        XCTAssertEqual(buffer.samples, [points[0], points[2]])
        var corrected = points[0]
        corrected.date.addTimeInterval(0.1)
        buffer.observe([corrected, points[2]], ending: origin)
        XCTAssertEqual(buffer.samples, [corrected, points[2]])
    }
    func testChartBufferResetsOnEmptyOrUnrelatedHistoryAndBoundsBursts() {
        let origin = Date(timeIntervalSince1970: 1000)
        func sample(_ offset: Int) -> HistorySample {
            HistorySample(date: origin.addingTimeInterval(Double(offset) / 10), cpu: 20, memPercent: 30, rxRate: 40, txRate: 50)
        }
        var buffer = HistoryChartBuffer()
        buffer.observe([sample(0), sample(1)], ending: origin)
        buffer.observe([sample(10000)], ending: origin.addingTimeInterval(1000))
        XCTAssertEqual(buffer.samples, [sample(10000)])
        buffer.observe([], ending: origin)
        XCTAssertTrue(buffer.samples.isEmpty)
        for offset in 0...500 {
            buffer.observe((max(0, offset - 119)...offset).map(sample), ending: origin.addingTimeInterval(Double(offset) / 10))
            XCTAssertLessThanOrEqual(buffer.samples.count, 241)
        }
    }
    func testSparklineSlidesAndClipsBothEdgesWithoutChangingExistingY() {
        let origin = Date(timeIntervalSince1970: 1000), now = Date(timeIntervalSince1970: 5000)
        let history = [-1, 0, 1, 119, 120, 121].map {
            HistorySample(date: origin.addingTimeInterval(Double($0)), cpu: $0 % 2 == 0 ? 90 : 10, memPercent: 20, rxRate: 30, txRate: 40)
        }
        var clock = HistoryChartClock()
        clock.observe(history.last?.date, now: now)
        let size = CGSize(width: 480, height: 38)
        let initial = SparklineProjection.points(history, ending: clock.end(at: now), size: size)
        for frame in 0...3 {
            let fraction = Double(frame) / 4
            let points = SparklineProjection.points(history, ending: clock.end(at: now.addingTimeInterval(fraction)), size: size)
            XCTAssertLessThan(points.first!.x, 0)
            XCTAssertGreaterThan(points.last!.x, size.width)
            for index in points.indices {
                XCTAssertEqual(points[index].x, initial[index].x - fraction * 4, accuracy: 0.00001)
                XCTAssertEqual(points[index].y, initial[index].y)
            }
            XCTAssertEqual(points[2].x, 4 * (1 - fraction), accuracy: 0.00001)
            XCTAssertEqual(size.width - points[4].x, 4 * fraction, accuracy: 0.00001)
        }
    }
    func testSparklineProjectionHandlesEmptyInvalidAndOutOfRangeInput() {
        let now = Date(timeIntervalSince1970: 1000), size = CGSize(width: 120, height: 40)
        XCTAssertTrue(SparklineProjection.points([], ending: now, size: size).isEmpty)
        var point = HistorySample(date: now, cpu: .nan, memPercent: 0, rxRate: 0, txRate: 0)
        XCTAssertTrue(SparklineProjection.points([point], ending: now, size: size).isEmpty)
        point.cpu = 150
        XCTAssertEqual(SparklineProjection.points([point], ending: now, size: size), [CGPoint(x: 120, y: 0)])
        point.cpu = -10
        XCTAssertEqual(SparklineProjection.points([point], ending: now, size: size), [CGPoint(x: 120, y: 40)])
        XCTAssertTrue(SparklineProjection.points([point], ending: now, size: .zero).isEmpty)
        point.date = Date(timeIntervalSince1970: .infinity)
        XCTAssertTrue(SparklineProjection.points([point], ending: now, size: size).isEmpty)
    }
    func testSharedChartFramesTreatSequencedAndLegacyWindowsIdentically() {
        let now = Date(timeIntervalSince1970: 5000), origin = Date(timeIntervalSince1970: 1000)
        var modern = HistoryChartBuffer(), legacy = HistoryChartBuffer()
        var modernClock = HistoryChartClock(), legacyClock = HistoryChartClock()
        for tick in 0...8 {
            let points = (tick..<(tick + 120)).map {
                HistorySample(date: origin.addingTimeInterval(Double($0)), cpu: Double($0 % 100), memPercent: 0, rxRate: 0, txRate: 0, seq: UInt32($0))
            }
            let unsequenced = points.map { point -> HistorySample in var point = point; point.seq = nil; return point }
            let poll = now.addingTimeInterval(Double(tick) + (tick % 2 == 0 ? 0 : 0.2))
            modernClock.observe(points.last?.date, now: poll)
            legacyClock.observe(unsequenced.last?.date, now: poll.addingTimeInterval(0.1))
            modern.observe(points, ending: modernClock.end(at: poll))
            legacy.observe(unsequenced, ending: legacyClock.end(at: poll.addingTimeInterval(0.1)))
            for frame in 0...3 {
                let date = now.addingTimeInterval(Double(tick) + Double(frame) / 4)
                let size = CGSize(width: 480, height: 38)
                let a = SparklineProjection.points(modern.samples, ending: modernClock.end(at: date), size: size)
                let b = SparklineProjection.points(legacy.samples, ending: legacyClock.end(at: date), size: size)
                XCTAssertEqual(a.count, b.count)
                for index in a.indices {
                    XCTAssertEqual(a[index].y, b[index].y)
                    XCTAssertEqual(a[index].x - b[index].x, -0.4, accuracy: 0.00001)
                }
            }
        }
    }
    @MainActor func testDemoChartStreamsExerciseDirectHistoryAndLegacyRelay() async {
        let suite = "DemoStreams-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "demoChartStreams")
        let store = MonitorStore(defaults: defaults, secrets: MemorySecrets())
        store.demoMode = true
        await store.refresh()
        let firstKeys = store.nodes.map(\.key)
        await store.refresh()
        XCTAssertEqual(store.nodes.count, 2)
        XCTAssertEqual(store.nodes.map(\.key), firstKeys)
        let modern = store.nodes.first { $0.historyWindow.cursor != nil }!
        let legacy = store.nodes.first { $0.historyWindow.cursor == nil }!
        XCTAssertFalse(modern.endToEnd)
        XCTAssertTrue(legacy.endToEnd)
        XCTAssertNotEqual(modern.endpointID, legacy.endpointID)
        XCTAssertEqual(modern.history.count, 120)
        XCTAssertTrue(modern.history.allSatisfy { $0.seq != nil })
        XCTAssertEqual(legacy.history.count, 2)
        XCTAssertTrue(legacy.history.allSatisfy { $0.seq == nil })
    }
    func testChartClockSlidesBetweenSamplesWithoutResettingEachPoll() {
        let now = Date(timeIntervalSince1970: 1000)
        var clock = HistoryChartClock()
        clock.observe(nil, now: now)
        XCTAssertEqual(clock.end(at: now).timeIntervalSince1970, 999)
        clock.observe(Date(timeIntervalSince1970: 900), now: now)
        XCTAssertEqual(clock.end(at: now).timeIntervalSince1970, 899)
        XCTAssertEqual(clock.end(at: now.addingTimeInterval(0.5)).timeIntervalSince1970, 899.5)
        clock.observe(Date(timeIntervalSince1970: 901), now: now.addingTimeInterval(1.2))
        XCTAssertEqual(clock.end(at: now.addingTimeInterval(1.2)).timeIntervalSince1970, 900.2, accuracy: 0.0001)
        clock.observe(Date(timeIntervalSince1970: 800), now: now.addingTimeInterval(2))
        XCTAssertEqual(clock.end(at: now.addingTimeInterval(2)).timeIntervalSince1970, 799)
    }
    func testChartMarksAreAbsoluteAndKeepTheirTextBetweenSeconds() {
        let first = HistoryChartClock.marks(ending: Date(timeIntervalSince1970: 1001))
        let second = HistoryChartClock.marks(ending: Date(timeIntervalSince1970: 1002))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.timeIntervalSince1970), [900, 930, 960, 990])
        let boundary = HistoryChartClock.marks(ending: Date(timeIntervalSince1970: 1020))
        XCTAssertEqual(boundary.map(\.timeIntervalSince1970), [900, 930, 960, 990, 1020])
        let after = HistoryChartClock.marks(ending: Date(timeIntervalSince1970: 1020.1))
        XCTAssertEqual(after.map(\.timeIntervalSince1970), [930, 960, 990, 1020])
        XCTAssertTrue(after.allSatisfy { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 30) == 0 })
    }
    func testChartScaleRoundsAndHoldsBeforeShrinking() {
        let now = Date(timeIntervalSince1970: 1000)
        var scale = HistoryChartScale()
        for invalid in [Double.nan, .infinity, -1, 0] { scale.observe(peak: invalid, now: now) }
        XCTAssertEqual(scale.upper, 1000)
        scale.observe(peak: 1800, now: now)
        XCTAssertEqual(scale.upper, 5000)
        for peak in [1700.0, 1900, 1801] { scale.observe(peak: peak, now: now) }
        XCTAssertEqual(scale.upper, 5000)
        scale.observe(peak: 900, now: now.addingTimeInterval(1))
        scale.observe(peak: 900, now: now.addingTimeInterval(30.9))
        XCTAssertEqual(scale.upper, 5000)
        scale.observe(peak: 900, now: now.addingTimeInterval(31))
        XCTAssertEqual(scale.upper, 2000)
        scale.observe(peak: 100_000, now: now.addingTimeInterval(32))
        XCTAssertEqual(scale.upper, 200_000)
        scale.observe(peak: 1000, now: now.addingTimeInterval(33))
        scale.observe(peak: 100_000, now: now.addingTimeInterval(60))
        scale.observe(peak: 1000, now: now.addingTimeInterval(61))
        scale.observe(peak: 1000, now: now.addingTimeInterval(62))
        XCTAssertEqual(scale.upper, 200_000)
        XCTAssertTrue(HistoryChartScale.roundedCeiling(Double.greatestFiniteMagnitude).isFinite)
    }
    func testChartLabelsKeepClearOfBothEdges() {
        let end = Date(timeIntervalSince1970: 1000)
        for age in [0.0, 11.9, 108.1, 120] {
            XCTAssertFalse(HistoryChartClock.showsLabel(at: end.addingTimeInterval(-age), ending: end))
        }
        for age in [12.0, 60, 108] {
            XCTAssertTrue(HistoryChartClock.showsLabel(at: end.addingTimeInterval(-age), ending: end))
        }
    }
    func testChartTicksUseRoundDisplayUnitsAndStayStable() {
        let now = Date(timeIntervalSince1970: 1000)
        var scale = HistoryChartScale()
        XCTAssertEqual(scale.ticks, [0, 500, 1000])
        scale.observe(peak: 180_000, now: now)
        XCTAssertEqual(scale.ticks.map { scale.label(for: $0) }, ["0B/s", "200K/s", "400K/s"])
        let ticks = scale.ticks
        scale.observe(peak: 179_000, now: now.addingTimeInterval(1))
        XCTAssertEqual(scale.ticks, ticks)
        scale.observe(peak: 1_000_000, now: now.addingTimeInterval(2))
        XCTAssertEqual(scale.ticks.map { scale.label(for: $0) }, ["0B/s", "0.5M/s", "1M/s", "1.5M/s"])
    }
    func testChartIdentitySurvivesRingEvictionAndValueCorrection() {
        let start = Date(timeIntervalSince1970: 1000)
        let points = (0..<120).map { HistorySample(date: start.addingTimeInterval(Double($0)), cpu: 1, memPercent: 2, rxRate: 3, txRate: 4, seq: UInt32($0)) }
        let rolled = Array(points.dropFirst())
        XCTAssertEqual(points[1].chartID, rolled[0].chartID)
        var corrected = points[1]; corrected.cpu = 50
        XCTAssertEqual(corrected.chartID, points[1].chartID)
        corrected.seq = nil
        XCTAssertNotEqual(corrected.chartID, points[1].chartID)
        var legacy = corrected; legacy.rxRate = 100
        XCTAssertEqual(legacy.chartID, corrected.chartID)
    }

    @MainActor func testEncryptionBadgeMatchesEndpointTransport() {
        let suite = "Encryption-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, secrets: MemorySecrets())
        let transports: [(Endpoint.Kind, Bool)] = [
            (.direct(host: "localhost", port: 9000), true),
            (.https(urlString: "https://example.com"), false),
            (.groupTCP(host: "localhost", port: 9001), true),
            (.groupHTTPS(urlString: "https://example.com"), false)
        ]
        for (kind, encrypted) in transports {
            let endpoint = Endpoint(name: "入口", kind: kind)
            var snapshot = NodeSnapshot(); snapshot.id = "node"
            store.apply(endpoint, result: .success([]), latency: 1)
            XCTAssertFalse(store.nodes.contains { $0.endpointID == endpoint.id })
            store.apply(endpoint, result: .success([snapshot]), latency: 1)
            XCTAssertEqual(store.nodes.last?.usesEndToEndEncryption, encrypted)
            XCTAssertEqual(store.nodes.last?.endToEnd, kind.isGroup)
            if !kind.isGroup { XCTAssertEqual(store.nodes.last?.connectionLabel, L10n.text("直连")) }
            store.apply(endpoint, result: .failure(ProbeError.timeout), latency: 1)
            XCTAssertEqual(store.nodes.last?.usesEndToEndEncryption, encrypted)
            XCTAssertEqual(store.nodes.last?.online, false)
        }
    }

    func testIPAddressMasking() {
        for address in ["192.168.1.1", "2606:4700:4700::1111", "fe80::1%en0", "invalid-address", ""] {
            XCTAssertEqual(PulseFormat.ip(address, hidden: false), address)
            if !address.isEmpty { XCTAssertEqual(PulseFormat.ip(address, hidden: true), "•.•.•.•") }
        }
        XCTAssertEqual(PulseFormat.ip("192.168.1.1", hidden: true), "•.•.•.•")
        XCTAssertEqual(PulseFormat.ip("2606:4700:4700::1111", hidden: true), "•.•.•.•")
        XCTAssertEqual(PulseFormat.ip("", hidden: true), "")
    }

    @MainActor func testHiddenNodePersistencePollingAndFreshHistory() throws {
        let suite = "Hidden-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets(), store = MonitorStore(defaults: defaults, secrets: secrets)
        let endpoint = Endpoint(name: "入口", kind: .groupTCP(host: "localhost", port: 1))
        try store.save(endpoint, secret: "keep-secret", groupSecret: "keep-group")
        var own = NodeSnapshot(); own.id = "own"; own.name = "主机"
        var child = NodeSnapshot(); child.id = "child"; child.name = "子节点"
        store.apply(endpoint, result: .success([own, child]), latency: 1)
        let node = store.nodes[1]
        XCTAssertNil(store.removableEndpoint(for: node))
        XCTAssertNil(store.removableEndpoint(for: store.nodes[0]))
        XCTAssertThrowsError(try store.deleteNode(node, removeEndpoint: true))
        XCTAssertTrue(store.hiddenNodes.isEmpty)
        try store.deleteNode(node); try store.deleteNode(node)
        XCTAssertEqual(store.hiddenNodes.count, 1)
        XCTAssertEqual(store.nodes.map(\.snapshot.id), ["own"])
        XCTAssertNil(store.removableEndpoint(for: store.nodes[0]))
        let restoredStore = MonitorStore(defaults: defaults, secrets: secrets)
        restoredStore.apply(endpoint, result: .success([own, child]), latency: 1)
        restoredStore.apply(endpoint, result: .failure(ProbeError.timeout), latency: 1)
        restoredStore.apply(endpoint, result: .success([]), latency: 1)
        XCTAssertEqual(restoredStore.nodes.map(\.snapshot.id), ["own"])
        XCTAssertEqual(try restoredStore.secret(for: endpoint), "keep-secret")
        let hidden = try XCTUnwrap(restoredStore.hiddenNodes.first)
        restoredStore.restoreNode(hidden); restoredStore.restoreNode(hidden)
        restoredStore.apply(endpoint, result: .success([own, child]), latency: 1)
        XCTAssertEqual(restoredStore.nodes.last?.history.count, 1)
        XCTAssertTrue(MonitorStore(defaults: defaults, secrets: secrets).hiddenNodes.isEmpty)
    }

    @MainActor func testSoleNodeEndpointDeletionAndSecretFailure() throws {
        for kind in [Endpoint.Kind.direct(host: "localhost", port: 1), .https(urlString: "https://example.com")] {
            let suite = "Delete-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let secrets = MemorySecrets(), store = MonitorStore(defaults: defaults, secrets: secrets)
            let endpoint = Endpoint(name: "入口", kind: kind)
            try store.save(endpoint, secret: "remove-secret")
            var snapshot = NodeSnapshot(); snapshot.id = "sole"
            store.apply(endpoint, result: .success([snapshot]), latency: 1)
            let node = try XCTUnwrap(store.nodes.first)
            XCTAssertEqual(store.removableEndpoint(for: node), endpoint)
            secrets.failDelete = true
            XCTAssertThrowsError(try store.deleteNode(node, removeEndpoint: true))
            XCTAssertEqual(store.nodes.first?.history.count, 1)
            XCTAssertEqual(store.endpoints, [endpoint]); XCTAssertTrue(store.hiddenNodes.isEmpty)
            secrets.failDelete = false
            try store.deleteNode(node, removeEndpoint: true)
            XCTAssertTrue(store.nodes.isEmpty); XCTAssertTrue(store.endpoints.isEmpty)
            XCTAssertNil(store.statuses[endpoint.id]); XCTAssertNil(secrets.values[endpoint.id])
            XCTAssertTrue(MonitorStore(defaults: defaults, secrets: secrets).endpoints.isEmpty)
        }
    }

    @MainActor func testRelayHideIsolationAndEndpointCleanup() throws {
        let suite = "RelayHide-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets(), store = MonitorStore(defaults: defaults, secrets: secrets)
        let relay = Endpoint(name: "中继", kind: .groupTCP(host: "localhost", port: 1))
        let direct = Endpoint(name: "直连", kind: .direct(host: "localhost", port: 2))
        try store.save(relay, secret: "token", groupSecret: "group")
        try store.save(direct, secret: "direct")
        var snapshot = NodeSnapshot(); snapshot.id = "same-id"
        store.apply(relay, result: .success([snapshot]), latency: 1)
        store.apply(direct, result: .success([snapshot]), latency: 1)
        XCTAssertNil(store.removableEndpoint(for: store.nodes[0]))
        try store.deleteNode(store.nodes[0])
        store.apply(relay, result: .success([snapshot]), latency: 1)
        XCTAssertEqual(store.nodes.map(\.endpointID), [direct.id])
        XCTAssertEqual(try store.groupSecret(for: relay), "group")
        try store.delete(relay)
        XCTAssertTrue(store.hiddenNodes.isEmpty)
        XCTAssertNil(secrets.values[relay.id]); XCTAssertNil(secrets.groups[relay.id])
        XCTAssertEqual(store.endpoints, [direct])
    }

    func testConnectionLabelNeverRoutesDirectNodesThroughThemselves() {
        var snapshot = NodeSnapshot(); snapshot.name = "主机"
        var node = NodeItem(key: "node", endpointID: UUID(), endpointName: "主机", snapshot: snapshot, online: true)
        XCTAssertEqual(node.connectionLabel, L10n.text("直连"))
        node.endpointName = "自定义别名"
        XCTAssertEqual(node.connectionLabel, L10n.text("直连"))
        node.endToEnd = true
        XCTAssertEqual(node.connectionLabel, L10n.text("经由 %@", "自定义别名"))
        node.endpointName = "主机"
        XCTAssertEqual(node.connectionLabel, L10n.text("中继"))
        node.endpointName = ""
        XCTAssertEqual(node.connectionLabel, L10n.text("中继"))
    }

    func testCompactRateFormatting() {
        XCTAssertEqual(PulseFormat.compactRate(0), "0B/s")
        XCTAssertEqual(PulseFormat.compactRate(1536), "1.5K/s")
        XCTAssertEqual(PulseFormat.compactRate(125 * 1024 * 1024), "125M/s")
        XCTAssertEqual(PulseFormat.compactRate(-1), "0B/s")
        XCTAssertEqual(PulseFormat.compactRate(.infinity), "0B/s")
    }
    func testResponseBinding() throws {
        let rid = "0123456789abcdef0123456789abcdef"
        let crypto = ProbeCrypto(secret: "replay-test")
        let captured = try crypto.seal(json: Data("{\"ok\":true,\"rid\":\"\(rid)\",\"nodes\":[]}".utf8))
        let plaintext = try crypto.open(frame: captured)
        XCTAssertEqual(try DirectClient.decodeResponse(plaintext, requestID: rid), [])
        XCTAssertThrowsError(try DirectClient.decodeResponse(plaintext, requestID: String(repeating: "0", count: 32))) {
            XCTAssertEqual($0.localizedDescription, L10n.text("响应校验失败"))
        }
        XCTAssertThrowsError(try DirectClient.decodeResponse(Data(#"{"ok":true,"nodes":[]}"#.utf8), requestID: rid))
        XCTAssertThrowsError(try DirectClient.decodeResponse(Data(), requestID: rid))
    }
    func testCryptoRoundTrip() throws {
        let crypto = ProbeCrypto(secret: "秘密")
        let json = Data(#"{"op":"get","ts":1700000000}"#.utf8)
        XCTAssertEqual(try crypto.open(frame: crypto.seal(json: json)), json)
    }
    func testPythonFixedVector() throws {
        let hex = "0000001c000102030405060708090a0bee276e604b883ca74c7973e3cf57626c4247dd18b313a1f84d9617a8468fdd83c5d6dd03fdbe91af733f1e5d"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let crypto = ProbeCrypto(secret: "vector-secret")
        XCTAssertEqual(String(data: try crypto.open(frame: Data(bytes)), encoding: .utf8), #"{"op":"get","ts":1700000000}"#)
        var altered = Data(bytes); altered[altered.count - 1] ^= 1
        XCTAssertThrowsError(try crypto.open(frame: altered))
        XCTAssertThrowsError(try crypto.open(frame: Data(bytes.prefix(10))))
        XCTAssertThrowsError(try crypto.seal(json: Data()))
    }
    func testRealProbeAndMissingFields() throws {
        let sample = #"{"ok":true,"nodes":[{"id":"1b2efbfcf191aab6fd7615f7df9a77dfea87ba3c45c265da0ae4899f6c9e215c","name":"swift-test","hostname":"ip-172-16-4-2.us-west-2.compute.internal","os":"Darwin","kernel":"25.6.0","arch":"arm64","cpu_model":"","cpu_cores":12,"cpu_usage":0.0,"load":[4.42,12.72,12.77],"mem_total":0,"mem_used":0,"swap_total":0,"swap_used":0,"disk_total":131545956352,"disk_used":107959439360,"net_rx":0,"net_tx":0,"net_rx_rate":0.0,"net_tx_rate":0.0,"uptime":0.0,"procs":0,"tcp_conns":0,"temp":null,"ips":["172.16.4.2"],"ts":1795334822,"version":"0.1.0","relay":false}]}"#
        let node = try XCTUnwrap(ProbeResponse.decode(Data(sample.utf8)).first)
        XCTAssertEqual(node.cpuCores, 12); XCTAssertEqual(node.diskTotal, 131545956352)
        XCTAssertEqual(node.ips, ["172.16.4.2"]); XCTAssertNil(node.temp)
        let partial = try ProbeResponse.decode(Data(#"{"ok":true,"nodes":[{"id":"minimal","unknown":123},{"id":"bad-field","cpu_usage":"oops"}]}"#.utf8))
        XCTAssertEqual(partial.count, 2); XCTAssertEqual(partial[0].load, [])
        XCTAssertEqual(partial[1].cpuUsage, 0)
        XCTAssertEqual(try ProbeResponse.decode(Data(#"{"ok":true,"nodes":[]}"#.utf8)), [])
        XCTAssertThrowsError(try ProbeResponse.decode(Data("bad".utf8)))
    }
    func testURLs() throws {
        for input in ["https://example.com", "https://example.com/", "https://example.com/api/nodes", "https://example.com/api/nodes/"] {
            XCTAssertEqual(try HTTPSClient.nodesURL(input).absoluteString, "https://example.com/api/nodes")
        }
        XCTAssertEqual(try HTTPSClient.nodesURL("http://localhost:123/base/").path, "/base/api/nodes")
        XCTAssertThrowsError(try HTTPSClient.nodesURL("http://example.com"))
        XCTAssertThrowsError(try HTTPSClient.nodesURL("file:///tmp/foo"))
    }
    @MainActor func testStoreHistoryOfflineDemoAndPersistence() throws {
        let suite = "NodePulseTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, secrets: MemorySecrets())
        XCTAssertEqual(store.refreshInterval, 1)
        let endpoint = Endpoint(name: "test", kind: .direct(host: "localhost", port: 1))
        try store.save(endpoint, secret: "never-in-defaults")
        defer { try? store.delete(endpoint) }
        XCTAssertEqual(try store.secret(for: endpoint), "never-in-defaults")
        XCTAssertFalse(String(data: defaults.data(forKey: "endpoints")!, encoding: .utf8)!.contains("never-in-defaults"))
        XCTAssertEqual(MonitorStore(defaults: defaults).endpoints, [endpoint])
        var own = NodeSnapshot(); own.id = "self"; own.ts = 1000
        var relay = NodeSnapshot(); relay.id = "other"; relay.ts = 950
        for _ in 0..<125 { store.apply(endpoint, result: .success([own, relay]), latency: 10) }
        XCTAssertEqual(store.nodes[0].history.count, 120)
        XCTAssertTrue(store.nodes.allSatisfy { $0.online })
        store.apply(endpoint, result: .failure(ProbeError.timeout), latency: 6000)
        XCTAssertEqual(store.nodes.count, 2); XCTAssertTrue(store.nodes.allSatisfy { !$0.online })
        XCTAssertEqual(store.statuses[endpoint.id]?.error, L10n.text("超时"))
        XCTAssertNotNil(store.statuses[endpoint.id]?.lastSuccess)
        store.demoMode = true
    }
    @MainActor func testDemo() async {
        let suite = "Demo-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults); store.demoMode = true
        await store.refresh(); let first = store.nodes[0].snapshot.cpuUsage
        await store.refresh()
        XCTAssertEqual(store.nodes.count, 5); XCTAssertNotEqual(store.nodes[0].snapshot.cpuUsage, first)
        XCTAssertTrue(store.nodes.contains { !$0.online }); XCTAssertEqual(store.nodes[0].history.count, 120)
    }
    @MainActor func testDemoSeedAndLiveSamplesShareOneWaveform() async {
        let suite = "DemoSeam-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults); store.demoMode = true
        await store.refresh()
        for node in store.nodes {
            XCTAssertEqual(node.history.last!.rxRate, node.snapshot.netRxRate)
            XCTAssertEqual(node.history.last!.cpu, node.snapshot.cpuUsage)
            let index = Int(node.snapshot.id.dropFirst("demo-".count))!
            let origin = node.history.last!.date
            let before = MonitorStore.demoSample(at: origin.addingTimeInterval(-1), since: origin, index: index)
            let seam = MonitorStore.demoSample(at: origin, since: origin, index: index)
            let after = MonitorStore.demoSample(at: origin.addingTimeInterval(1), since: origin, index: index)
            XCTAssertLessThan(abs(after.rxRate - 2 * seam.rxRate + before.rxRate), 2600)
        }
        let seeded = store.nodes[0].history
        await store.refresh()
        XCTAssertEqual(Array(store.nodes[0].history.dropLast()), Array(seeded.suffix(119)))
        XCTAssertEqual(store.nodes[0].history.last!.rxRate, store.nodes[0].snapshot.netRxRate)
    }
    @MainActor func testSharedRelayFreshnessUsesAuthenticatedAge() {
        let suite = "Freshness-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = Endpoint(name: "shared", kind: .groupTCP(host: "localhost", port: 1))
        let now = Date(timeIntervalSince1970: 1000)
        let store = MonitorStore(defaults: defaults)
        var node = NodeSnapshot(); node.id = "relay"; node.ts = 995
        store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 5])
        XCTAssertTrue(store.nodes[0].online); XCTAssertTrue(store.nodes[0].endToEnd)
        store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 300])
        XCTAssertFalse(store.nodes[0].online)
        node.ts = 1
        store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 0])
        XCTAssertFalse(store.nodes[0].online)
        store.apply(endpoint, result: .success([node]), latency: 1, now: now)
        XCTAssertFalse(store.nodes[0].online)
    }
    func testLiveProbe() async throws {
        guard ProcessInfo.processInfo.environment["NPULSE_E2E"] == "1" else {
            throw XCTSkip("Set NPULSE_E2E=1; run host probe on 19090/19091 with integration-secret")
        }
        let direct = Endpoint(name: "live", kind: .direct(host: "127.0.0.1", port: 19090))
        let http = Endpoint(name: "live", kind: .https(urlString: "http://127.0.0.1:19091/"))
        let nodes = try await DirectClient().fetch(direct, secret: "integration-secret")
        let webNodes = try await HTTPSClient().fetch(http, secret: "integration-secret")
        XCTAssertGreaterThanOrEqual(nodes.count, 1); XCTAssertGreaterThanOrEqual(webNodes.count, 1)
        print("E2E PASS DirectClient nodes=\(nodes.count), HTTPSClient localhost nodes=\(webNodes.count)")
        do { _ = try await DirectClient().fetch(direct, secret: "wrong"); XCTFail("wrong key accepted") }
        catch { XCTAssertEqual(error.localizedDescription, L10n.text("密钥错误或被拒绝（对端静默断开）")) }
        do { _ = try await HTTPSClient().fetch(http, secret: "wrong"); XCTFail("wrong HTTP key accepted") }
        catch { XCTAssertEqual(error.localizedDescription, L10n.text("密钥错误或路径不对")) }
    }
    func testKeychainWhenSigned() throws {
        let secrets = SecretStore(), id = UUID()
        try secrets.set("test-value", for: id)
        defer { try? secrets.delete(id) }
        XCTAssertEqual(try secrets.get(id), "test-value")
    }
}

private final class HistoryRelayFixture: @unchecked Sendable {
    private let listener: NWListener
    private let legacy: Bool
    private let lock = NSLock()
    private var received: [Bool] = []
    var port: UInt16 { listener.port!.rawValue }
    var historyRequests: [Bool] { lock.lock(); defer { lock.unlock() }; return received }
    init(legacy: Bool) throws {
        self.legacy = legacy
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start(ready: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { if case .ready = $0 { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receive(connection, data: Data())
        }
        listener.start(queue: .global())
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            let bytes = data + (chunk ?? Data())
            if bytes.count >= 4 {
                let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                if length > ProbeCrypto.maxLength { connection.cancel(); return }
                if bytes.count >= length + 32 {
                    do {
                        let crypto = ProbeCrypto(secret: "token")
                        let request = try JSONSerialization.jsonObject(with: crypto.open(frame: bytes)) as! [String: Any]
                        let history = request["since"] != nil
                        self.lock.lock(); self.received.append(history); self.lock.unlock()
                        if self.legacy && history { connection.cancel(); return }
                        let response = try JSONSerialization.data(withJSONObject: ["ok": true, "rid": request["rid"]!, "blobs": []])
                        connection.send(content: try crypto.seal(json: response), completion: .contentProcessed { _ in connection.cancel() })
                    } catch { connection.cancel() }
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { self.receive(connection, data: bytes) }
        }
    }
}

private final class MemorySecrets: SecretStorage {
    var failDelete = false
    var values: [UUID: String] = [:]
    var groups: [UUID: String] = [:]
    func set(_ secret: String, for id: UUID) { values[id] = secret }
    func get(_ id: UUID) throws -> String {
        guard let value = values[id] else { throw ProbeError.missingSecret }
        return value
    }
    func delete(_ id: UUID) throws {
        if failDelete { throw ProbeError.keychain(-1) }
        values[id] = nil
    }
    func setGroup(_ secret: String, for id: UUID) { groups[id] = secret }
    func getGroup(_ id: UUID) throws -> String {
        guard let value = groups[id] else { throw ProbeError.missingSecret }
        return value
    }
    func deleteGroup(_ id: UUID) { groups[id] = nil }
}
