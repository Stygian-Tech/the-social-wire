import Foundation
import Synchronization
import Testing
@testable import ATProtoCore

@Suite struct TIDTests {
    @Test func encodesAndDecodesMicroseconds() throws {
        let tid = TID(microseconds: 1_726_000_000_000_000, clockID: 7)
        #expect(tid.rawValue.count == 13)
        #expect(tid.microseconds == 1_726_000_000_000_000)
        #expect(try TID(tid.rawValue) == tid)
    }

    @Test func zeroIsAllTwos() {
        #expect(TID(microseconds: 0, clockID: 0).rawValue == "2222222222222")
    }

    @Test func rejectsInvalidStrings() {
        #expect(throws: SyntaxError.self) { try TID("kzzzzzzzzzzzz") }
        #expect(throws: SyntaxError.self) { try TID("222222222222") }
    }

    @Test func generatorIsStrictlyIncreasingWithFrozenClock() {
        let frozen = Date(timeIntervalSince1970: 1_726_000_000)
        let generator = TIDGenerator(clockID: 1, now: { frozen })
        let tids = (0..<100).map { _ in generator.next() }
        #expect(tids == tids.sorted())
        #expect(Set(tids).count == 100)
    }
}
