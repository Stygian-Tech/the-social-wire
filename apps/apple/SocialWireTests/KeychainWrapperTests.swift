import Foundation
import Testing
@testable import SocialWire

@Suite("KeychainWrapper")
struct KeychainWrapperTests {
    private let wrapper = KeychainWrapper()
    private let testKey = "test.keychainwrapper.\(UUID().uuidString)"

    @Test("stores and retrieves a string value")
    func storeAndRetrieve() {
        wrapper.set("hello", forKey: testKey)
        #expect(wrapper.string(forKey: testKey) == "hello")
        wrapper.remove(forKey: testKey)
    }

    @Test("overwrites an existing value")
    func overwrite() {
        wrapper.set("first", forKey: testKey)
        wrapper.set("second", forKey: testKey)
        #expect(wrapper.string(forKey: testKey) == "second")
        wrapper.remove(forKey: testKey)
    }

    @Test("returns nil for missing key")
    func missingKey() {
        let result = wrapper.string(forKey: "definitely.does.not.exist.\(UUID().uuidString)")
        #expect(result == nil)
    }

    @Test("remove returns true even when key doesn't exist")
    func removeNonExistent() {
        let removed = wrapper.remove(forKey: "no.such.key.\(UUID().uuidString)")
        #expect(removed == true)
    }

    @Test("stores and removes successfully")
    func removeExisting() {
        let key = "test.remove.\(UUID().uuidString)"
        wrapper.set("value", forKey: key)
        let removed = wrapper.remove(forKey: key)
        #expect(removed == true)
        #expect(wrapper.string(forKey: key) == nil)
    }
}
