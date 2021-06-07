//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import <SignalServiceKit/BaseModel.h>

NS_ASSUME_NONNULL_BEGIN

@class Contact;
@class SignalRecipient;
@class SignalServiceAddress;

// This class represents a single valid Signal account.
//
// * Contacts with multiple signal accounts will correspond to
//   multiple instances of SignalAccount.
// * For non-contacts, the contact property will be nil.
@interface SignalAccount : BaseModel

/// An E164 value identifying the signal account.
@property (nullable, nonatomic, readonly) NSString *recipientPhoneNumber;

/// A UUID identifying the signal account.
@property (nullable, nonatomic, readonly) NSString *recipientUUID;

/// An address representing the signal account. This will be
/// the UUID, if defined, otherwise it will be the E164 number.
@property (nonatomic, readonly) SignalServiceAddress *recipientAddress;

// This property is optional and will not be set for
// non-contact account.
@property (nonatomic, nullable, readonly) Contact *contact;

// We cache the contact avatar data on this class.
//
// contactAvatarHash is the hash of the original avatar
// data (if any) from the system contact.  We use it for
// change detection.
//
// contactAvatarJpegData contains the data we'll sync
// to Desktop. We only want to send valid avatar images.
// Converting the avatars to JPEGs isn't deterministic
// and our contact sync de-bouncing logic is based
// on the actual data sent over the wire, so we need
// to cache this as well.
//
// This property is optional and will not be set for
// non-contact account.
@property (nonatomic, nullable, readonly) NSData *contactAvatarHash;
@property (nonatomic, nullable, readonly) NSData *contactAvatarJpegData;

// For contacts with more than one signal account,
// this is a label for the account.
@property (nonatomic, readonly) NSString *multipleAccountLabelText;

- (nullable NSString *)contactPreferredDisplayName;
- (nullable NSString *)contactFullName;
- (nullable NSString *)contactFirstName;
- (nullable NSString *)contactLastName;
- (nullable NSString *)contactNicknameIfAvailable;
- (nullable NSPersonNameComponents *)contactPersonNameComponents;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithUniqueId:(NSString *)uniqueId NS_UNAVAILABLE;
- (instancetype)initWithGrdbId:(int64_t)grdbId uniqueId:(NSString *)uniqueId NS_UNAVAILABLE;

// Convenience initializer which is neither "designated" nor "unavailable".
- (instancetype)initWithSignalRecipient:(SignalRecipient *)signalRecipient
                                contact:(nullable Contact *)contact
               multipleAccountLabelText:(nullable NSString *)multipleAccountLabelText;

// Convenience initializer which is neither "designated" nor "unavailable".
- (instancetype)initWithSignalServiceAddress:(SignalServiceAddress *)address NS_SWIFT_NAME(init(address:));

- (instancetype)initWithSignalServiceAddress:(SignalServiceAddress *)serviceAddress
                                     contact:(nullable Contact *)contact
                    multipleAccountLabelText:(nullable NSString *)multipleAccountLabelText NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithContact:(nullable Contact *)contact
              contactAvatarHash:(nullable NSData *)contactAvatarHash
          contactAvatarJpegData:(nullable NSData *)contactAvatarJpegData
       multipleAccountLabelText:(NSString *)multipleAccountLabelText
           recipientPhoneNumber:(nullable NSString *)recipientPhoneNumber
                  recipientUUID:(nullable NSString *)recipientUUID NS_DESIGNATED_INITIALIZER;

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
                         contact:(nullable Contact *)contact
               contactAvatarHash:(nullable NSData *)contactAvatarHash
           contactAvatarJpegData:(nullable NSData *)contactAvatarJpegData
        multipleAccountLabelText:(NSString *)multipleAccountLabelText
            recipientPhoneNumber:(nullable NSString *)recipientPhoneNumber
                   recipientUUID:(nullable NSString *)recipientUUID
NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(grdbId:uniqueId:contact:contactAvatarHash:contactAvatarJpegData:multipleAccountLabelText:recipientPhoneNumber:recipientUUID:));

// clang-format on

// --- CODE GENERATION MARKER

- (BOOL)hasSameContent:(SignalAccount *)other;

- (void)tryToCacheContactAvatarData;

- (void)updateWithContact:(nullable Contact *)contact
              transaction:(SDSAnyWriteTransaction *)transaction NS_SWIFT_NAME(updateWithContact(_:transaction:));

#if TESTABLE_BUILD
- (void)replaceContactForTests:(nullable Contact *)contact NS_SWIFT_NAME(replaceContactForTests(_:));
#endif

@end

NS_ASSUME_NONNULL_END
