//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Represents a collection of download requests (usually all spawned from one source).
internal protocol OWSAttachmentDownloadJobRequest {

    var jobs: [OWSAttachmentDownloads.Job] { get }
}

extension OWSAttachmentDownloadJobRequest {

    var isEmpty: Bool { jobs.isEmpty }
}

extension OWSAttachmentDownloads {

    internal enum JobType {
        case messageAttachment(attachmentId: AttachmentId, messageUniqueId: String)
        case storyMessageAttachment(attachmentId: AttachmentId, storyMessage: StoryMessage)
        case contactSync(attachmentPointer: TSAttachmentPointer)

        var attachmentId: AttachmentId {
            switch self {
            case .messageAttachment(let attachmentId, _):
                return attachmentId
            case .storyMessageAttachment(let attachmentId, _):
                return attachmentId
            case .contactSync(let attachmentPointer):
                return attachmentPointer.uniqueId
            }
        }
    }

    // MARK: - JobRequests

    internal typealias JobRequest = OWSAttachmentDownloadJobRequest

    internal struct ContactSyncJobRequest: OWSAttachmentDownloadJobRequest {

        let job: Job

        var jobs: [Job] { [job] }

        init(attachmentPointer: TSAttachmentPointer) {
            job = Job(
                jobType: .contactSync(attachmentPointer: attachmentPointer),
                category: .contactSync,
                // Headless downloads always bypass.
                downloadBehavior: .bypassAll
            )
        }
    }

    internal struct StoryMessageJobRequest: OWSAttachmentDownloadJobRequest {

        // Stories only ever have one attachment.
        let job: Job

        var jobs: [Job] { [job] }

        init?(
            storyMessage: StoryMessage,
            downloadBehavior: AttachmentDownloadBehavior,
            tx: SDSAnyReadTransaction
        ) {
            let attachmentPointer: TSAttachmentPointer? = {
                switch storyMessage.attachment {
                case .file, .foreignReferenceAttachment:
                    guard let attachment = storyMessage.fileAttachment(tx: tx) else {
                        owsFailDebug("Missing attachment: \(storyMessage.timestamp)")
                        return nil
                    }
                    guard let pointer = attachment as? TSAttachmentPointer else {
                        // Ignore already downloaded attachments
                        return nil
                    }
                    return pointer
                case .text(let attachment):
                    guard let attachmentId = attachment.preview?.imageAttachmentId else {
                        return nil
                    }
                    return TSAttachmentPointer.anyFetchAttachmentPointer(uniqueId: attachmentId, transaction: tx)
                }
            }()
            guard let attachmentPointer else {
                return nil
            }

            let jobType = JobType.storyMessageAttachment(
                attachmentId: attachmentPointer.uniqueId,
                storyMessage: storyMessage
            )

            let category: AttachmentCategory
            switch storyMessage.attachment {
            case .text:
                category = .linkedPreviewThumbnail
            case .file, .foreignReferenceAttachment:
                category = attachmentPointer.downloadCategoryForMimeType
            }

            self.job = Job(
                jobType: jobType,
                category: category,
                downloadBehavior: downloadBehavior
            )
        }
    }

    internal struct MessageJobRequest: OWSAttachmentDownloadJobRequest {
        // Not every attachment may get a job, if some are downloaded or are duplicates.
        private let bodyAttachmentJobs: [Job]
        // But every body attachment that can be downloaded gets a promise, including
        // duplicates and already-downloaded ones.
        let bodyAttachmentPromises: [Promise<TSAttachmentStream>]

        private let linkPreviewJob: Job?
        let linkPreviewPromise: Promise<TSAttachmentStream>?

        private let quotedReplyThumbnailJob: Job?
        let quotedReplyThumbnailPromise: Promise<TSAttachmentStream>?

        private let contactShareAvatarJob: Job?
        let contactShareAvatarPromise: Promise<TSAttachmentStream>?

        private let stickerJob: Job?
        let stickerPromise: Promise<TSAttachmentStream>?

        var jobs: [OWSAttachmentDownloads.Job] {
            return (
                bodyAttachmentJobs
                + [linkPreviewJob]
                + [quotedReplyThumbnailJob]
                + [contactShareAvatarJob]
                + [stickerJob]
            ).compacted()
        }

        init(
            message: TSMessage,
            attachmentGroup: AttachmentGroup,
            downloadBehavior: AttachmentDownloadBehavior,
            tx: SDSAnyReadTransaction
        ) {
            // From attachment unique id to the promise on the job created for it.
            // For duplicates; we schedule once but hold the promise for each reference.
            var existingPromises = [AttachmentId: Promise<TSAttachmentStream>]()

            func buildJob(attachment: TSAttachment, category: AttachmentCategory) -> (Job?, Promise<TSAttachmentStream>) {
                if let attachmentStream = attachment as? TSAttachmentStream {
                    // Already downloaded! no job, but return a succeeded promise.
                    return (nil, .value(attachmentStream))
                }

                let attachmentId: AttachmentId = attachment.uniqueId

                if let existingPromise = existingPromises[attachmentId] {
                    return (nil, existingPromise)
                }

                let jobType = JobType.messageAttachment(attachmentId: attachmentId, messageUniqueId: message.uniqueId)
                let job = Job(jobType: jobType, category: category, downloadBehavior: downloadBehavior)

                existingPromises[attachmentId] = job.promise

                return (job, job.promise)
            }

            func buildJob(attachmentId: AttachmentId, category: AttachmentCategory) -> (Job?, Promise<TSAttachmentStream>)? {
                guard let attachment = TSAttachment.anyFetch(uniqueId: attachmentId, transaction: tx) else {
                    owsFailDebug("Missing attachment: \(attachmentId)")
                    return nil
                }
                return buildJob(attachment: attachment, category: category)
            }

            // Body attachments go first both because they are always fetched (the other types
            // are conditionally fetched) AND because they have the highest priority
            // and therefore should be put into existingPromises first.

            var bodyAttachmentJobs = [Job]()
            var bodyAttachmentPromises = [Promise<TSAttachmentStream>]()
            for attachment in message.bodyAttachments(with: tx) {
                let category: AttachmentCategory = {
                    if attachment.isImageMimeType {
                        return .bodyMediaImage
                    } else if attachment.isVideoMimeType {
                        return .bodyMediaVideo
                    } else if attachment.isVoiceMessage(inContainingMessage: message, transaction: tx) {
                        return .bodyAudioVoiceMemo
                    } else if attachment.isAudioMimeType {
                        return .bodyAudioOther
                    } else if attachment.isOversizeTextMimeType {
                        return .bodyOversizeText
                    } else {
                        return .bodyFile
                    }
                }()
                let (job, promise) = buildJob(attachment: attachment, category: category)
                if let job {
                    bodyAttachmentJobs.append(job)
                }
                bodyAttachmentPromises.append(promise)
            }

            self.bodyAttachmentJobs = bodyAttachmentJobs
            self.bodyAttachmentPromises = bodyAttachmentPromises

            if attachmentGroup.justBodyAttachments {
                self.linkPreviewJob = nil
                self.linkPreviewPromise = nil
                self.quotedReplyThumbnailJob = nil
                self.quotedReplyThumbnailPromise = nil
                self.contactShareAvatarJob = nil
                self.contactShareAvatarPromise = nil
                self.stickerJob = nil
                self.stickerPromise = nil
                return
            }

            // We only want to kick off a thumbnail fetching job if:
            // - The thumbnail attachment is owned by the quoted message content (so it's solely responsible for fetching)
            // - It's an unfetched pointer
            if message.quotedMessage?.isThumbnailOwned == true,
               let attachment = message.quotedMessage?.fetchThumbnail(with: tx),
               attachment is TSAttachmentPointer
            {
                let jobNPromise = buildJob(attachment: attachment, category: .quotedReplyThumbnail)
                self.quotedReplyThumbnailJob = jobNPromise.0
                self.quotedReplyThumbnailPromise = jobNPromise.1
            } else {
                self.quotedReplyThumbnailJob = nil
                self.quotedReplyThumbnailPromise = nil
            }

            if let attachmentId = message.contactShare?.avatarAttachmentId {
                let jobNPromise = buildJob(attachmentId: attachmentId, category: .contactShareAvatar)
                self.contactShareAvatarJob = jobNPromise?.0
                self.contactShareAvatarPromise = jobNPromise?.1
            } else {
                self.contactShareAvatarJob = nil
                self.contactShareAvatarPromise = nil
            }

            if let attachmentId = message.linkPreview?.imageAttachmentId {
                let jobNPromise = buildJob(attachmentId: attachmentId, category: .linkedPreviewThumbnail)
                self.linkPreviewJob = jobNPromise?.0
                self.linkPreviewPromise = jobNPromise?.1
            } else {
                self.linkPreviewJob = nil
                self.linkPreviewPromise = nil
            }

            if let attachmentId = message.messageSticker?.attachmentId {
                if let attachment = TSAttachment.anyFetch(uniqueId: attachmentId, transaction: tx) {
                    owsAssertDebug(attachment.byteCount > 0)
                    let autoDownloadSizeThreshold: UInt32 = 100 * 1024
                    let category: AttachmentCategory
                    if attachment.byteCount > autoDownloadSizeThreshold {
                        category = .stickerLarge
                    } else {
                        category = .stickerSmall
                    }
                    let jobNPromise = buildJob(attachment: attachment, category: category)
                    self.stickerJob = jobNPromise.0
                    self.stickerPromise = jobNPromise.1
                } else {
                    owsFailDebug("Missing attachment: \(attachmentId)")
                    self.stickerJob = nil
                    self.stickerPromise = nil
                }
            } else {
                self.stickerJob = nil
                self.stickerPromise = nil
            }
        }
    }

    // MARK: - Job

    /// Represents a request for a single download, and the promise for that download.
    internal class Job {
        let jobType: JobType
        let category: AttachmentCategory
        let downloadBehavior: AttachmentDownloadBehavior

        let promise: Promise<TSAttachmentStream>
        let future: Future<TSAttachmentStream>

        var progress: CGFloat = 0
        var attachmentId: AttachmentId { jobType.attachmentId }

        init(
            jobType: JobType,
            category: AttachmentCategory,
            downloadBehavior: AttachmentDownloadBehavior
        ) {

            self.jobType = jobType
            self.category = category
            self.downloadBehavior = downloadBehavior

            let (promise, future) = Promise<TSAttachmentStream>.pending()
            self.promise = promise
            self.future = future
        }

        func loadLatestAttachment(transaction: SDSAnyReadTransaction) -> TSAttachment? {
            return TSAttachment.anyFetch(uniqueId: attachmentId, transaction: transaction)
        }
    }
}

private extension TSAttachmentPointer {

    var downloadCategoryForMimeType: OWSAttachmentDownloads.AttachmentCategory {
        // Story messages cant be voice message, so no `bodyAudioVoiceMemo`
        if isImageMimeType {
            return .bodyMediaImage
        } else if isVideoMimeType {
            return .bodyMediaVideo
        } else if isAudioMimeType {
            return .bodyAudioOther
        } else if isOversizeTextMimeType {
            return .bodyOversizeText
        } else {
            return .bodyFile
        }
    }
}
