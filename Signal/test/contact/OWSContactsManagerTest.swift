//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import Signal
@testable import SignalMessaging
@testable import SignalServiceKit

class OWSContactsManagerTest: SignalBaseTest {
    private let dbV2: MockDB = .init()

    private let mockUsernameLookupMananger: MockUsernameLookupManager = .init()

    override func setUp() {
        super.setUp()

        // Create local account.
        databaseStorage.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx.asV2Write
            )
        }

        // Replace the fake contacts manager with the real one just for this test.
        SSKEnvironment.shared.setContactsManagerForUnitTests(makeContactsManager())
    }

    override func tearDown() {
        mockUsernameLookupMananger.clearAllUsernames()
    }

    private func makeContactsManager() -> OWSContactsManager {
        let contactsManager = OWSContactsManager(swiftValues: OWSContactsManagerSwiftValues(
            usernameLookupManager: mockUsernameLookupMananger
        ))

        contactsManager.setUpSystemContacts()

        return contactsManager
    }

    private func createRecipients(_ serviceIds: [ServiceId]) {
        let recipientFetcher = DependenciesBridge.shared.recipientFetcher
        let recipientManager = DependenciesBridge.shared.recipientManager
        write { tx in
            for serviceId in serviceIds {
                recipientManager.markAsRegisteredAndSave(
                    recipientFetcher.fetchOrCreate(serviceId: serviceId, tx: tx.asV2Write),
                    shouldUpdateStorageService: false,
                    tx: tx.asV2Write
                )
            }
        }
    }

    private func createAccounts(_ accounts: [SignalAccount]) {
        write { transaction in
            for account in accounts {
                account.anyInsert(transaction: transaction)
            }
        }
    }

    private func createContacts(_ contacts: [Contact]) {
        write { transaction in
            (self.contactsManager as! OWSContactsManager).setContactsMaps(
                .build(contacts: contacts, localNumber: LocalIdentifiers.forUnitTests.phoneNumber),
                localNumber: LocalIdentifiers.forUnitTests.phoneNumber,
                transaction: transaction
            )
        }
    }

    private func makeAccount(
        serviceId: ServiceId,
        phoneNumber: E164,
        name: String? = nil
    ) -> SignalAccount {
        let contact = name.map { name -> Contact in
            makeContact(phoneNumber: phoneNumber, name: name)
        }

        return SignalAccount(
            contact: contact,
            contactAvatarHash: nil,
            multipleAccountLabelText: "home",
            recipientPhoneNumber: phoneNumber.stringValue,
            recipientServiceId: serviceId
        )
    }

    private func makeContact(phoneNumber: E164, name: String) -> Contact {
        let parts = name.components(separatedBy: " ")
        return Contact(
            phoneNumber: phoneNumber.stringValue,
            phoneNumberLabel: "home",
            givenName: parts.first,
            familyName: parts.dropFirst().first,
            nickname: nil,
            fullName: name
        )
    }

    // MARK: - Display Names

    func testGetDisplayNamesWithCachedContactNames() {
        let addresses = [
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550100"),
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550101"),
        ]
        createRecipients(addresses.map { $0.serviceId! })
        createAccounts(zip(addresses, ["Alice Aliceson", "Bob Bobson"]).map { address, name in
            makeAccount(serviceId: address.serviceId!, phoneNumber: address.e164!, name: name)
        })

        read { transaction in
            let contactsManager = self.contactsManager as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, transaction: transaction)
            let expected = ["Alice Aliceson (home)", "Bob Bobson (home)"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesWithProfileFullNames() {
        let addresses = [SignalServiceAddress.randomForTesting(), SignalServiceAddress.randomForTesting()]
        (self.profileManager as! OWSFakeProfileManager).fakeDisplayNames = [
            addresses[0]: "Alice Aliceson",
            addresses[1]: "Bob Bobson"
        ]
        read { transaction in
            let contactsManager = self.contactsManager as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, transaction: transaction)
            let expected = ["Alice Aliceson", "Bob Bobson"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesWithPhoneNumbers() {
        let addresses = [
            SignalServiceAddress(phoneNumber: "+17035559900"),
            SignalServiceAddress(phoneNumber: "+17035559901")
        ]
        // Prevent default fake name from being used.
        (self.profileManager as! OWSFakeProfileManager).fakeDisplayNames = [:]
        read { transaction in
            let contactsManager = self.contactsManager as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, transaction: transaction)
            let expected = ["+17035559900", "+17035559901"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesWithUserNames() {
        let aliceAci = Aci.randomForTesting()
        let bobAci = Aci.randomForTesting()

        let addresses = [SignalServiceAddress(aliceAci), SignalServiceAddress(bobAci)]

        // Store some fake usernames.

        dbV2.write { transaction in
            mockUsernameLookupMananger.saveUsername("alice", forAci: aliceAci, transaction: transaction)
            mockUsernameLookupMananger.saveUsername("bob", forAci: bobAci, transaction: transaction)
        }

        // Prevent default fake names from being used.
        (profileManager as! OWSFakeProfileManager).fakeDisplayNames = [:]

        read { transaction in
            let contactsManager = self.contactsManager as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, transaction: transaction)
            let expected = ["alice", "bob"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesUnknown() {
        let addresses = [SignalServiceAddress.randomForTesting(), SignalServiceAddress.randomForTesting()]

        // Intentionally do not set any mock usernames. Additionally, prevent
        // default fake names from being used.
        (profileManager as! OWSFakeProfileManager).fakeDisplayNames = [:]

        read { transaction in
            let contactsManager = self.contactsManager as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, transaction: transaction)
            let expected = ["Unknown", "Unknown"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesMixed() {
        let aliceAci = Aci.randomForTesting()
        let aliceAddress = SignalServiceAddress(serviceId: aliceAci, phoneNumber: "+16505550100")
        let aliceAccount = makeAccount(serviceId: aliceAci, phoneNumber: aliceAddress.e164!, name: "Alice Aliceson")
        createRecipients([aliceAci])
        createAccounts([aliceAccount])

        let bobAddress = SignalServiceAddress.randomForTesting()
        (profileManager as! OWSFakeProfileManager).fakeDisplayNames = [bobAddress: "Bob Bobson"]

        let carolAddress = SignalServiceAddress(phoneNumber: "+17035559900")

        let daveAci = Aci.randomForTesting()
        let daveAddress = SignalServiceAddress(daveAci)
        dbV2.write { transaction in
            mockUsernameLookupMananger.saveUsername("dave", forAci: daveAci, transaction: transaction)
        }

        let eveAddress = SignalServiceAddress.randomForTesting()

        read { transaction in
            let contactsManager = self.contactsManager as! OWSContactsManager
            let addresses = [aliceAddress, bobAddress, carolAddress, daveAddress, eveAddress]
            let actual = contactsManager.displayNames(for: addresses, transaction: transaction)
            let expected = ["Alice Aliceson (home)", "Bob Bobson", "+17035559900", "dave", "Unknown"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testSinglePartName() {
        let addresses = [
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550100"),
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550101"),
        ]
        createRecipients(addresses.map { $0.serviceId! })
        createAccounts(zip(addresses, ["Alice", "Bob"]).map { address, name in
            makeAccount(serviceId: address.serviceId!, phoneNumber: address.e164!, name: name)
        })

        read { transaction in
            let contactsManager = self.contactsManager as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, transaction: transaction)
            let expected = ["Alice (home)", "Bob (home)"]
            XCTAssertEqual(actual, expected)
        }
    }

    // MARK: - Cached Contact Names

    func testCachedContactNamesWithAccounts() {
        let addresses = [
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550100"),
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550101"),
        ]
        createRecipients(addresses.map { $0.serviceId! })
        createAccounts(zip(addresses, ["Alice Aliceson", "Bob Bobson"]).map { address, name in
            makeAccount(serviceId: address.serviceId!, phoneNumber: address.e164!, name: name)
        })
        let contactsManager = makeContactsManager()
        read { transaction in
            let actual = contactsManager.systemContactNames(for: AnySequence(addresses), tx: transaction)
            let expected = ["Alice Aliceson (home)", "Bob Bobson (home)"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testCachedContactNameWithNonSignalContactsLackingPhoneNumbers() {
        let addresses = [SignalServiceAddress.randomForTesting(), SignalServiceAddress.randomForTesting()]
        let contactsManager = makeContactsManager()
        read { transaction in
            let actual = contactsManager.systemContactNames(for: AnySequence(addresses), tx: transaction)
            XCTAssertEqual(actual, [nil, nil])
        }
    }

    func testCachedContactNameMixed() {
        // Register alice with an account that has a full name.
        let aliceAci = Aci.randomForTesting()
        let aliceAddress = SignalServiceAddress(serviceId: aliceAci, phoneNumber: "+16505550100")
        let aliceAccount = makeAccount(serviceId: aliceAci, phoneNumber: aliceAddress.e164!, name: "Alice Aliceson")
        createRecipients([aliceAci])
        createAccounts([aliceAccount])

        // Who the heck is Chuck?
        let chuckAddress = SignalServiceAddress.randomForTesting()

        let contactsManager = makeContactsManager()
        read { transaction in
            let addresses = [aliceAddress, chuckAddress]
            let actual = contactsManager.systemContactNames(for: AnySequence(addresses), tx: transaction)
            let expected = ["Alice Aliceson (home)", nil]
            XCTAssertEqual(actual, expected)
        }
    }
}
