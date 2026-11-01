import XCTest
import Security
@testable import OpenPushCore

/// The device credential links this install to its subscription; losing it on
/// an upgrade makes the server create a second subscription.
///
/// `DeviceCredentialStoreTests` drives the store against an in-memory Keychain
/// that keeps the accessibility class, so the update-in-place and migration
/// rules run on every leg. `DeviceCredentialStoreKeychainTests` repeats the
/// upgrade against the real Keychain; it needs a process with a Keychain
/// entitlement (an app-hosted test bundle on iOS) and skips elsewhere.
final class DeviceCredentialStoreTests: XCTestCase {
    /// One generic-password table keyed by service, account and access group.
    final class FakeKeychain: @unchecked Sendable {
        struct Item { var data: Data; var accessible: String }
        private let lock = NSLock()
        private var items: [String: Item] = [:]
        private(set) var deletes = 0
        private(set) var adds = 0
        var failUpdates = false

        private func key(_ query: [String: Any]) -> String {
            [query[kSecAttrService as String] as? String ?? "",
             query[kSecAttrAccount as String] as? String ?? "",
             query[kSecAttrAccessGroup as String] as? String ?? ""].joined(separator: "|")
        }

        func item(_ store: DeviceCredentialStore) -> Item? {
            lock.withLock {
                items[[store.service, store.account, store.accessGroup ?? ""]
                    .joined(separator: "|")]
            }
        }

        func put(_ store: DeviceCredentialStore, _ value: String, accessible: CFString) {
            lock.withLock {
                items[[store.service, store.account, store.accessGroup ?? ""]
                    .joined(separator: "|")] = Item(data: Data(value.utf8),
                                                    accessible: accessible as String)
            }
        }

        var calls: DeviceCredentialStore.Keychain {
            DeviceCredentialStore.Keychain(
                copyMatching: { query in
                    self.lock.withLock {
                        guard let item = self.items[self.key(query)] else {
                            return (errSecItemNotFound, nil)
                        }
                        let result: [String: Any] = [
                            kSecValueData as String: item.data,
                            kSecAttrAccessible as String: item.accessible,
                        ]
                        return (errSecSuccess, result as CFDictionary)
                    }
                },
                add: { attributes in
                    self.lock.withLock {
                        let key = self.key(attributes)
                        guard self.items[key] == nil else { return errSecDuplicateItem }
                        self.adds += 1
                        self.items[key] = Item(
                            data: attributes[kSecValueData as String] as? Data ?? Data(),
                            accessible: attributes[kSecAttrAccessible as String] as? String
                                ?? kSecAttrAccessibleWhenUnlocked as String)
                        return errSecSuccess
                    }
                },
                update: { query, changes in
                    self.lock.withLock {
                        if self.failUpdates { return errSecInteractionNotAllowed }
                        let key = self.key(query)
                        guard var item = self.items[key] else { return errSecItemNotFound }
                        if let data = changes[kSecValueData as String] as? Data { item.data = data }
                        if let accessible = changes[kSecAttrAccessible as String] as? String {
                            item.accessible = accessible
                        }
                        self.items[key] = item
                        return errSecSuccess
                    }
                },
                delete: { query in
                    self.lock.withLock {
                        self.deletes += 1
                        return self.items.removeValue(forKey: self.key(query)) == nil
                            ? errSecItemNotFound : errSecSuccess
                    }
                })
        }
    }

    private let thisDeviceOnly = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private var fake: FakeKeychain!
    private var store: DeviceCredentialStore!

    override func setUp() {
        super.setUp()
        fake = FakeKeychain()
        store = DeviceCredentialStore(service: "ai.openpush.tests", accessGroup: "TEAM.group",
                                      keychain: fake.calls)
    }

    func testAnItemSavedTheOldWayIsStillLoadedAndMovedToThisDeviceOnly() {
        fake.put(store, "opdev_existing", accessible: kSecAttrAccessibleAfterFirstUnlock)

        XCTAssertEqual(store.load(), "opdev_existing",
                       "the upgrade must keep the credential, or the server makes a duplicate")
        XCTAssertEqual(fake.item(store)?.accessible, thisDeviceOnly)
        XCTAssertEqual(fake.item(store)?.data, Data("opdev_existing".utf8))
        XCTAssertEqual(fake.deletes, 0, "migrated in place, never deleted and re-added")
        XCTAssertEqual(fake.adds, 0)
    }

    func testAFailedMigrationStillReturnsTheCredentialAndRetriesNextTime() {
        fake.put(store, "opdev_existing", accessible: kSecAttrAccessibleAfterFirstUnlock)
        fake.failUpdates = true

        XCTAssertEqual(store.load(), "opdev_existing")
        XCTAssertEqual(fake.item(store)?.accessible,
                       kSecAttrAccessibleAfterFirstUnlock as String)

        fake.failUpdates = false
        XCTAssertEqual(store.load(), "opdev_existing")
        XCTAssertEqual(fake.item(store)?.accessible, thisDeviceOnly)
        XCTAssertEqual(fake.deletes, 0)
    }

    func testSaveOverAnExistingItemUpdatesItInPlace() {
        fake.put(store, "opdev_old", accessible: kSecAttrAccessibleAfterFirstUnlock)

        XCTAssertEqual(store.save("opdev_new"), errSecSuccess)

        XCTAssertEqual(store.load(), "opdev_new")
        XCTAssertEqual(fake.item(store)?.accessible, thisDeviceOnly)
        XCTAssertEqual(fake.deletes, 0, "no delete-then-add window that could lose the credential")
        XCTAssertEqual(fake.adds, 0)
    }

    func testAFailedSaveLeavesTheStoredCredentialAlone() {
        fake.put(store, "opdev_old", accessible: kSecAttrAccessibleAfterFirstUnlock)
        fake.failUpdates = true

        XCTAssertNotEqual(store.save("opdev_new"), errSecSuccess)

        XCTAssertEqual(fake.item(store)?.data, Data("opdev_old".utf8),
                       "the earlier store deleted first, so a failed add lost the credential")
    }

    func testSaveAddsWhenNothingIsStored() {
        XCTAssertNil(store.load())

        XCTAssertEqual(store.save("opdev_first"), errSecSuccess)

        XCTAssertEqual(store.load(), "opdev_first")
        XCTAssertEqual(fake.item(store)?.accessible, thisDeviceOnly)
        XCTAssertEqual(fake.adds, 1)
    }

    func testAnItemAlreadyThisDeviceOnlyIsNotRewritten() {
        fake.put(store, "opdev_value", accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        fake.failUpdates = true

        XCTAssertEqual(store.load(), "opdev_value")
    }

    func testWipeStillRemovesTheCredential() {
        store.save("opdev_value")

        store.wipe()

        XCTAssertNil(store.load())
    }

    func testThePublicInitializerUsesTheSystemKeychain() {
        let store = DeviceCredentialStore(service: "s", account: "a", accessGroup: "g")
        XCTAssertEqual(store.service, "s")
        XCTAssertEqual(store.account, "a")
        XCTAssertEqual(store.accessGroup, "g")
    }
}

/// The same upgrade against the real Keychain. An unhosted test bundle (the
/// package's own `xcodebuild test` on the simulator) has no Keychain
/// entitlement and gets `errSecMissingEntitlement`, and the macOS host's
/// file-based keychain ignores the accessibility class, so both skip. Run it
/// from an app-hosted test target to exercise the system calls.
final class DeviceCredentialStoreKeychainTests: XCTestCase {
    private var store: DeviceCredentialStore!

    override func setUpWithError() throws {
        #if !os(iOS)
        throw XCTSkip("the accessibility class is only kept by the iOS Keychain")
        #else
        store = DeviceCredentialStore(service: "ai.openpush.tests.\(UUID().uuidString)")
        let probe = store.save("probe")
        if probe == errSecMissingEntitlement {
            throw XCTSkip("this test process has no Keychain entitlement; run app-hosted")
        }
        XCTAssertEqual(probe, errSecSuccess)
        store.wipe()
        #endif
    }

    override func tearDown() {
        store?.wipe()
        super.tearDown()
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: store.service,
         kSecAttrAccount as String: store.account]
    }

    private func items() -> [[String: Any]] {
        var search = query
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess else {
            return []
        }
        return result as? [[String: Any]] ?? []
    }

    func testAnItemSavedTheOldWayIsStillLoadedAndMovedToThisDeviceOnly() throws {
        // Written exactly as the earlier store wrote it.
        var attrs = query
        attrs[kSecValueData as String] = Data("opdev_existing".utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        XCTAssertEqual(SecItemAdd(attrs as CFDictionary, nil), errSecSuccess)

        XCTAssertEqual(store.load(), "opdev_existing")

        XCTAssertEqual(items().count, 1, "migrated in place, not copied")
        XCTAssertEqual(items().first?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(store.load(), "opdev_existing")
    }

    func testSaveUpdatesInPlace() throws {
        XCTAssertEqual(store.save("opdev_first"), errSecSuccess)
        XCTAssertEqual(store.save("opdev_second"), errSecSuccess)

        XCTAssertEqual(store.load(), "opdev_second")
        XCTAssertEqual(items().count, 1)
        XCTAssertEqual(items().first?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
