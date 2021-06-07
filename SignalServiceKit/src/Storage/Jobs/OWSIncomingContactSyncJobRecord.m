//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import <SignalServiceKit/OWSIncomingContactSyncJobRecord.h>

@implementation OWSIncomingContactSyncJobRecord

+ (NSString *)defaultLabel
{
    return @"IncomingContactSync";
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    return [super initWithCoder:coder];
}

- (instancetype)initWithAttachmentId:(NSString *)attachmentId label:(NSString *)label
{
    self = [super initWithLabel:label];
    _attachmentId = attachmentId;
    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
                    failureCount:(NSUInteger)failureCount
                           label:(NSString *)label
                          sortId:(unsigned long long)sortId
                          status:(SSKJobRecordStatus)status
                    attachmentId:(NSString *)attachmentId
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId
                      failureCount:failureCount
                             label:label
                            sortId:sortId
                            status:status];

    if (!self) {
        return self;
    }

    _attachmentId = attachmentId;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

@end
