//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalCoreKit

@objc
public class OWSAttachmentDownloads: NSObject {

    public typealias AttachmentId = String

    private static let unfairLock = UnfairLock()
    // This property should only be accessed with unfairLock.
    private var activeJobMap = [AttachmentId: Job]()
    // This property should only be accessed with unfairLock.
    private var jobQueue = [Job]()
    private var completeAttachmentMap = LRUCache<AttachmentId, Bool>(maxSize: 256)

    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(profileWhitelistDidChange(notification:)),
            name: UserProfileNotifications.profileWhitelistDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: .OWSApplicationDidBecomeActive,
            object: nil
        )

        AppReadiness.runNowOrWhenMainAppDidBecomeReadyAsync { self.startPendingNewMessageDownloads() }
    }

    @objc
    func profileWhitelistDidChange(notification: Notification) {
        AssertIsOnMainThread()

        // If a thread was newly whitelisted, try and start any
        // downloads that were pending on a message request.
        Self.databaseStorage.read { transaction in
            guard let whitelistedThread = ({ () -> TSThread? in
                if let address = notification.userInfo?[UserProfileNotifications.profileAddressKey] as? SignalServiceAddress,
                   address.isValid,
                   Self.profileManager.isUser(inProfileWhitelist: address, transaction: transaction) {
                    return TSContactThread.getWithContactAddress(address, transaction: transaction)
                }
                if let groupId = notification.userInfo?[UserProfileNotifications.profileGroupIdKey] as? Data,
                   Self.profileManager.isGroupId(inProfileWhitelist: groupId, transaction: transaction) {
                    return TSGroupThread.fetch(groupId: groupId, transaction: transaction)
                }
                return nil
            }()) else {
                return
            }
            self.enqueueDownloadOfAllAttachments(forThread: whitelistedThread,
                                                 transaction: transaction)
        }
    }

    @objc
    func applicationDidBecomeActive() {
        AppReadiness.runNowOrWhenMainAppDidBecomeReadyAsync { self.startPendingNewMessageDownloads() }
    }

    // MARK: -

    private static let pendingNewMessageDownloads = SDSKeyValueStore(collection: "PendingNewMessageDownloads")
    private static let pendingNewStoryMessageDownloads = SDSKeyValueStore(collection: "PendingNewStoryMessageDownloads")

    private func startPendingNewMessageDownloads() {
        owsAssertDebug(CurrentAppContext().isMainApp)

        let (pendingNewMessageDownloads, pendingNewStoryMessageDownloads) = databaseStorage.read { transaction in
            (
                Self.pendingNewMessageDownloads.allUIntValuesMap(transaction: transaction),
                Self.pendingNewStoryMessageDownloads.allUIntValuesMap(transaction: transaction)
            )
        }

        guard !pendingNewMessageDownloads.isEmpty || !pendingNewStoryMessageDownloads.isEmpty else { return }

        databaseStorage.asyncWrite { transaction in
            self.processPendingMessages(
                pendingNewMessageDownloads,
                store: Self.pendingNewMessageDownloads,
                transaction: transaction
            ) { pendingNewMessageId, downloadBehavior in
                self.enqueueDownloadOfAttachmentsForNewMessageId(
                    pendingNewMessageId,
                    downloadBehavior: downloadBehavior,
                    touchMessageImmediately: true,
                    transaction: transaction
                )
            }

            self.processPendingMessages(
                pendingNewStoryMessageDownloads,
                store: Self.pendingNewStoryMessageDownloads,
                transaction: transaction
            ) { pendingNewStoryMessageId, downloadBehavior in
                self.enqueueDownloadOfAttachmentsForNewStoryMessageId(
                    pendingNewStoryMessageId,
                    downloadBehavior: downloadBehavior,
                    touchMessageImmediately: true,
                    transaction: transaction
                )
            }
        }
    }

    private func processPendingMessages(
        _ pendingMessages: [String: UInt],
        store: SDSKeyValueStore,
        transaction: SDSAnyWriteTransaction,
        enqueue: (String, AttachmentDownloadBehavior) -> Void
    ) {
        for (uniqueId, rawDownloadBehavior) in pendingMessages {
            guard let downloadBehavior = AttachmentDownloadBehavior(rawValue: rawDownloadBehavior) else {
                owsFailDebug("Unexpected download behavior \(rawDownloadBehavior)")
                store.removeValue(forKey: uniqueId, transaction: transaction)
                continue
            }

            enqueue(uniqueId, downloadBehavior)
        }
    }

    // MARK: -

    public func downloadProgress(forAttachmentId attachmentId: AttachmentId) -> CGFloat? {
        Self.unfairLock.withLock {
            if let job = activeJobMap[attachmentId] {
                return job.progress
            }
            if nil != completeAttachmentMap[attachmentId] {
                return 1.0
            }
            return nil
        }
    }

    // MARK: -

    private func enqueueJob(job: Job) {
        Self.unfairLock.withLock {
            jobQueue.append(job)
        }

        tryToStartNextDownload()
    }

    private func dequeueNextJob() -> Job? {
        Self.unfairLock.withLock {
            let kMaxSimultaneousDownloads: Int = CurrentAppContext().isNSE ? 1 : 4
            guard activeJobMap.count < kMaxSimultaneousDownloads else {
                return nil
            }
            guard let job = jobQueue.first else {
                return nil
            }
            jobQueue.remove(at: 0)
            guard activeJobMap[job.attachmentId] == nil else {
                // Ensure we only have one download in flight at a time for a given attachment.
                Logger.warn("Ignoring duplicate download.")
                return nil
            }
            activeJobMap[job.attachmentId] = job
            return job
        }
    }

    private func markJobComplete(_ job: Job, isAttachmentDownloaded: Bool) {
        Self.unfairLock.withLock {
            let attachmentId = job.attachmentId

            owsAssertDebug(activeJobMap[attachmentId] != nil)
            activeJobMap[attachmentId] = nil

            cancellationRequestMap[attachmentId] = nil

            if isAttachmentDownloaded {
                owsAssertDebug(nil == completeAttachmentMap[attachmentId])
                completeAttachmentMap[attachmentId] = true
            }
        }
        tryToStartNextDownload()
    }

    private func tryToStartNextDownload() {
        Self.serialQueue.async {
            guard let job = self.dequeueNextJob() else {
                return
            }

            guard let attachmentPointer = self.prepareDownload(job: job) else {
                // Abort.
                self.markJobComplete(job, isAttachmentDownloaded: false)
                return
            }

            firstly { () -> Promise<TSAttachmentStream> in
                self.retrieveAttachment(job: job, attachmentPointer: attachmentPointer)
            }.done(on: Self.serialQueue) { (attachmentStream: TSAttachmentStream) in
                self.downloadDidSucceed(attachmentStream: attachmentStream, job: job)
            }.catch(on: Self.serialQueue) { (error: Error) in
                self.downloadDidFail(error: error, job: job)
            }
        }
    }

    private func prepareDownload(job: Job) -> TSAttachmentPointer? {
        Self.databaseStorage.write { (transaction) -> TSAttachmentPointer? in
            // Fetch latest to ensure we don't overwrite an attachment stream, resurrect an attachment, etc.
            guard let attachment = job.loadLatestAttachment(transaction: transaction) else {
                // This isn't necessarily a bug.  For example:
                //
                // * Receive an incoming message with an attachment.
                // * Kick off download of that attachment.
                // * Receive read receipt for that message, causing it to be disappeared immediately.
                // * Try to download that attachment - but it's missing.
                Logger.warn("Missing attachment: \(job.category).")
                return nil
            }
            guard let attachmentPointer = attachment as? TSAttachmentPointer else {
                // This isn't necessarily a bug.
                //
                // * An attachment may have been re-enqueued for download while it was already being downloaded.
                owsFailDebug("Attachment already downloaded: \(job.category).")

                Self.unfairLock.withLock {
                    owsAssertDebug(nil == completeAttachmentMap[job.attachmentId])
                    completeAttachmentMap[job.attachmentId] = true
                }

                return nil
            }

            switch job.jobType {
            case .messageAttachment(_, let messageUniqueId):
                if DebugFlags.forceAttachmentDownloadFailures.get() {
                    Logger.info("Skipping media download for thread due to debug settings: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .failed,
                                                                   transaction: transaction)
                    return nil
                }

                if self.isDownloadBlockedByActiveCall(job: job) {
                    Logger.info("Skipping media download due to active call: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .pendingManualDownload,
                                                                   transaction: transaction)
                    return nil
                }
                guard let message = TSMessage.anyFetchMessage(uniqueId: messageUniqueId, transaction: transaction) else {
                    Logger.info("Skipping media download due to missing message: \(job.category).")
                    return nil
                }
                let blockedByPendingMessageRequest = self.isDownloadBlockedByPendingMessageRequest(
                    job: job,
                    attachmentPointer: attachmentPointer,
                    message: message,
                    tx: transaction
                )
                if blockedByPendingMessageRequest {
                    Logger.info("Skipping media download for thread with pending message request: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .pendingMessageRequest,
                                                                   transaction: transaction)
                    return nil
                }
                let blockedByAutoDownloadSettings = self.isDownloadBlockedByAutoDownloadSettings(
                    job: job,
                    attachmentPointer: attachmentPointer,
                    transaction: transaction
                )
                if blockedByAutoDownloadSettings {
                    Logger.info("Skipping media download for thread due to auto-download settings: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .pendingManualDownload,
                                                                   transaction: transaction)
                    return nil
                }
            case .storyMessageAttachment:
                if DebugFlags.forceAttachmentDownloadFailures.get() {
                    Logger.info("Skipping media download for thread due to debug settings: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .failed,
                                                                   transaction: transaction)
                    return nil
                }

                if self.isDownloadBlockedByActiveCall(job: job) {
                    Logger.info("Skipping media download due to active call: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .pendingManualDownload,
                                                                   transaction: transaction)
                    return nil
                }
                let blockedByAutoDownloadSettings = self.isDownloadBlockedByAutoDownloadSettings(
                    job: job,
                    attachmentPointer: attachmentPointer,
                    transaction: transaction
                )
                if blockedByAutoDownloadSettings {
                    Logger.info("Skipping media download for thread due to auto-download settings: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .pendingManualDownload,
                                                                   transaction: transaction)
                    return nil
                }
            case .contactSync:
                // We don't need to apply attachment download settings
                // to contact sync attachments.
                break
            }

            Logger.info("Downloading: \(job.category).")

            attachmentPointer.updateAttachmentPointerState(.downloading, transaction: transaction)

            Self.touchAssociatedElement(for: job.jobType, tx: transaction)

            return attachmentPointer
        }
    }

    private func isDownloadBlockedByActiveCall(job: Job) -> Bool {

        guard !job.downloadBehavior.bypassPendingManualDownload else {
            return false
        }

        switch job.category {
        case .bodyMediaImage, .bodyMediaVideo:
            break
        case .bodyAudioVoiceMemo, .bodyOversizeText:
            return false
        case .bodyAudioOther, .bodyFile:
            break
        case .stickerSmall:
            return false
        case .stickerLarge:
            break
        case .quotedReplyThumbnail, .linkedPreviewThumbnail, .contactShareAvatar:
            return false
        case .contactSync:
            return false
        }

        return CurrentAppContext().hasActiveCall
    }

    private func isDownloadBlockedByPendingMessageRequest(
        job: Job,
        attachmentPointer: TSAttachmentPointer,
        message: TSMessage,
        tx: SDSAnyReadTransaction
    ) -> Bool {

        guard !job.downloadBehavior.bypassPendingMessageRequest else {
            return false
        }

        if DebugFlags.forceAttachmentDownloadPendingMessageRequest.get() {
            return true
        }

        guard attachmentPointer.isVisualMediaMimeType, message.messageSticker == nil, !message.isViewOnceMessage else {
            return false
        }

        guard message.isIncoming else {
            return false
        }

        // If there's not a thread, err on the safe side and don't download it.
        guard let thread = message.thread(tx: tx) else {
            return true
        }

        // If the message that created this attachment was the first message in the
        // thread, the thread may not yet be marked visible. In that case, just
        // check if the thread is whitelisted. We know we just received a message.
        // TODO: Mark the thread visible before this point to share more logic.
        guard thread.shouldThreadBeVisible else {
            return !Self.profileManager.isThread(inProfileWhitelist: thread, transaction: tx)
        }

        return ThreadFinder().hasPendingMessageRequest(thread: thread, transaction: tx)
    }

    private func isDownloadBlockedByAutoDownloadSettings(
        job: Job,
        attachmentPointer: TSAttachmentPointer,
        transaction: SDSAnyReadTransaction
    ) -> Bool {

        guard !job.downloadBehavior.bypassPendingManualDownload else {
            return false
        }

        if DebugFlags.forceAttachmentDownloadPendingManualDownload.get() {
            return true
        }

        let autoDownloadableMediaTypes = Self.autoDownloadableMediaTypes(transaction: transaction)

        switch job.category {
        case .bodyMediaImage:
            return !autoDownloadableMediaTypes.contains(.photo)
        case .bodyMediaVideo:
            return !autoDownloadableMediaTypes.contains(.video)
        case .bodyAudioVoiceMemo, .bodyOversizeText:
            return false
        case .bodyAudioOther:
            return !autoDownloadableMediaTypes.contains(.audio)
        case .bodyFile:
            return !autoDownloadableMediaTypes.contains(.document)
        case .stickerSmall:
            return false
        case .stickerLarge:
            return !autoDownloadableMediaTypes.contains(.photo)
        case .quotedReplyThumbnail, .linkedPreviewThumbnail, .contactShareAvatar:
            return false
        case .contactSync:
            return false
        }
    }

    private func downloadDidSucceed(attachmentStream: TSAttachmentStream,
                                    job: Job) {
        Logger.verbose("Attachment download succeeded.")

        if job.category.isSticker,
           let filePath = attachmentStream.originalFilePath {
            let imageMetadata = NSData.imageMetadata(withPath: filePath, mimeType: nil)
            if imageMetadata.imageFormat != .unknown,
               let mimeTypeFromMetadata = imageMetadata.mimeType {
                attachmentStream.replaceUnsavedContentType(mimeTypeFromMetadata)
            }
        }

        Self.databaseStorage.write { transaction in
            guard let attachmentPointer = job.loadLatestAttachment(transaction: transaction) as? TSAttachmentPointer else {
                Logger.warn("Attachment pointer no longer exists.")
                return
            }
            attachmentPointer.anyRemove(transaction: transaction)
            attachmentStream.anyInsert(transaction: transaction)

            Self.touchAssociatedElement(for: job.jobType, tx: transaction)
        }

        // TODO: Should we fulfill() if the attachmentPointer no longer existed?
        job.future.resolve(attachmentStream)

        markJobComplete(job, isAttachmentDownloaded: true)
    }

    private func downloadDidFail(error: Error, job: Job) {
        Logger.error("Attachment download failed with error: \(error)")

        Self.databaseStorage.write { transaction in
            // Fetch latest to ensure we don't overwrite an attachment stream, resurrect an attachment, etc.
            guard let attachmentPointer = job.loadLatestAttachment(transaction: transaction) as? TSAttachmentPointer else {
                Logger.warn("Attachment pointer no longer exists.")
                return
            }
            switch attachmentPointer.state {
            case .failed, .pendingMessageRequest, .pendingManualDownload:
                owsFailDebug("Unexpected state: \(NSStringForTSAttachmentPointerState(attachmentPointer.state))")
            case .enqueued, .downloading:
                // If the download was cancelled, mark as paused.                
                if case AttachmentDownloadError.cancelled = error {
                    attachmentPointer.updateAttachmentPointerState(.pendingManualDownload, transaction: transaction)
                } else {
                    attachmentPointer.updateAttachmentPointerState(.failed, transaction: transaction)
                }
            }

            Self.touchAssociatedElement(for: job.jobType, tx: transaction)
        }

        job.future.reject(error)

        markJobComplete(job, isAttachmentDownloaded: false)
    }

    private static func touchAssociatedElement(for jobType: JobType, tx: SDSAnyWriteTransaction) {
        switch jobType {
        case .messageAttachment(attachmentId: _, messageUniqueId: let messageUniqueId):
            touchLatestVersionOfMessage(uniqueId: messageUniqueId, tx: tx)
        case .storyMessageAttachment(attachmentId: _, storyMessage: let storyMessage):
            databaseStorage.touch(storyMessage: storyMessage, transaction: tx)
        case .contactSync:
            break
        }
    }

    private static func touchLatestVersionOfMessage(uniqueId: String, tx: SDSAnyWriteTransaction) {
        guard let latestMessage = TSMessage.anyFetchMessage(uniqueId: uniqueId, transaction: tx) else {
            // This path could happen in practice but should be very rare.
            owsFailDebug("Message has been deleted.")
            return
        }
        // We need to re-index as we may have just downloaded an attachment
        // that affects index content (e.g. oversize text attachment).
        Self.databaseStorage.touch(interaction: latestMessage, shouldReindex: true, transaction: tx)
    }

    // MARK: - Cancellation

    // This property should only be accessed with unfairLock.
    private var cancellationRequestMap = [String: Date]()

    public func cancelDownload(attachmentId: AttachmentId) {
        Self.unfairLock.withLock {
            cancellationRequestMap[attachmentId] = Date()
        }
    }

    private func shouldCancelJob(downloadState: DownloadState) -> Bool {
        Self.unfairLock.withLock {
            guard let cancellationDate = cancellationRequestMap[downloadState.job.attachmentId] else {
                return false
            }
            return cancellationDate > downloadState.startDate
        }
    }
}

// MARK: - Settings

@objc
public enum AttachmentDownloadBehavior: UInt, Equatable {
    case `default`
    case bypassPendingMessageRequest
    case bypassPendingManualDownload
    case bypassAll

    public static var defaultValue: MediaBandwidthPreference { .wifiAndCellular }

    public var bypassPendingMessageRequest: Bool {
        switch self {
        case .bypassPendingMessageRequest, .bypassAll:
            return true
        default:
            return false
        }
    }

    public var bypassPendingManualDownload: Bool {
        switch self {
        case .bypassPendingManualDownload, .bypassAll:
            return true
        default:
            return false
        }
    }
}

// MARK: -

public enum MediaBandwidthPreference: UInt, Equatable, CaseIterable {
    case never
    case wifiOnly
    case wifiAndCellular

    public var sortKey: UInt {
        switch self {
        case .never:
            return 1
        case .wifiOnly:
            return 2
        case .wifiAndCellular:
            return 3
        }
    }
}

// MARK: -

public enum MediaDownloadType: String, Equatable, CaseIterable {
    case photo
    case video
    case audio
    case document

    public var defaultPreference: MediaBandwidthPreference {
        switch self {
        case .photo:
            return .wifiAndCellular
        case .video:
            return .wifiOnly
        case .audio:
            return .wifiAndCellular
        case .document:
            return .wifiOnly
        }
    }

    public var sortKey: UInt {
        switch self {
        case .photo:
            return 1
        case .video:
            return 2
        case .audio:
            return 3
        case .document:
            return 4
        }
    }
}

// MARK: -

public extension OWSAttachmentDownloads {

    private static let keyValueStore = SDSKeyValueStore(collection: "MediaBandwidthPreferences")

    static let mediaBandwidthPreferencesDidChange = Notification.Name("MediaBandwidthPreferencesDidChange")

    static func set(mediaBandwidthPreference: MediaBandwidthPreference,
                    forMediaDownloadType mediaDownloadType: MediaDownloadType,
                    transaction: SDSAnyWriteTransaction) {
        keyValueStore.setUInt(mediaBandwidthPreference.rawValue,
                              key: mediaDownloadType.rawValue,
                              transaction: transaction)

        transaction.addAsyncCompletionOffMain {
            NotificationCenter.default.postNotificationNameAsync(mediaBandwidthPreferencesDidChange, object: nil)
        }
    }

    static func mediaBandwidthPreference(forMediaDownloadType mediaDownloadType: MediaDownloadType,
                                         transaction: SDSAnyReadTransaction) -> MediaBandwidthPreference {
        guard let rawValue = keyValueStore.getUInt(mediaDownloadType.rawValue,
                                                   transaction: transaction) else {
            return mediaDownloadType.defaultPreference
        }
        guard let value = MediaBandwidthPreference(rawValue: rawValue) else {
            owsFailDebug("Invalid value: \(rawValue)")
            return mediaDownloadType.defaultPreference
        }
        return value
    }

    static func resetMediaBandwidthPreferences(transaction: SDSAnyWriteTransaction) {
        for mediaDownloadType in MediaDownloadType.allCases {
            keyValueStore.removeValue(forKey: mediaDownloadType.rawValue, transaction: transaction)
        }
        transaction.addAsyncCompletionOffMain {
            NotificationCenter.default.postNotificationNameAsync(mediaBandwidthPreferencesDidChange, object: nil)
        }
    }

    static func loadMediaBandwidthPreferences(transaction: SDSAnyReadTransaction) -> [MediaDownloadType: MediaBandwidthPreference] {
        var result = [MediaDownloadType: MediaBandwidthPreference]()
        for mediaDownloadType in MediaDownloadType.allCases {
            result[mediaDownloadType] = mediaBandwidthPreference(forMediaDownloadType: mediaDownloadType,
                                                                 transaction: transaction)
        }
        return result
    }

    private static func autoDownloadableMediaTypes(transaction: SDSAnyReadTransaction) -> Set<MediaDownloadType> {
        let preferenceMap = loadMediaBandwidthPreferences(transaction: transaction)
        let hasWifiConnection = reachabilityManager.isReachable(via: .wifi)
        var result = Set<MediaDownloadType>()
        for (mediaDownloadType, preference) in preferenceMap {
            switch preference {
            case .never:
                continue
            case .wifiOnly:
                if hasWifiConnection {
                    result.insert(mediaDownloadType)
                }
            case .wifiAndCellular:
                result.insert(mediaDownloadType)
            }
        }
        return result
    }
}

// MARK: - Enqueue

public extension OWSAttachmentDownloads {

    func enqueueContactSyncDownload(attachmentPointer: TSAttachmentPointer) -> Promise<TSAttachmentStream> {
        let jobRequest = ContactSyncJobRequest(attachmentPointer: attachmentPointer)
        enqueueDownload(jobRequest: jobRequest)
        return jobRequest.job.promise
    }

    private func enqueueDownload(jobRequest: JobRequest) {
        guard !CurrentAppContext().isRunningTests else {
            Self.serialQueue.async {
                jobRequest.jobs.forEach {
                    $0.future.reject(OWSAttachmentDownloads.buildError())
                }
            }
            return
        }

        Self.serialQueue.async {
            Self.databaseStorage.read { transaction in
                self.enqueueJobs(
                    jobRequest: jobRequest,
                    transaction: transaction
                )
            }
        }
    }

    @objc
    func enqueueDownloadOfAllAttachments(
        forThread thread: TSThread,
        transaction: SDSAnyReadTransaction
    ) {
        do {
            let finder = InteractionFinder(threadUniqueId: thread.uniqueId)
            try finder.enumerateMessagesWithAttachments(transaction: transaction) { (message, _) in
                self.enqueueDownloadOfAttachments(
                    forMessageId: message.uniqueId,
                    attachmentGroup: .allAttachments,
                    downloadBehavior: .default,
                    touchMessageImmediately: false
                )
            }
        } catch {
            owsFailDebug("Error: \(error)")
        }
    }

    @objc
    func enqueueDownloadOfAttachmentsForNewMessage(_ message: TSMessage, transaction: SDSAnyWriteTransaction) {
        // No attachments, nothing to do.
        guard !message.allAttachmentIds(transaction: transaction).isEmpty else { return }

        enqueueDownloadOfAttachmentsForNewMessageId(
            message.uniqueId,
            downloadBehavior: message is TSOutgoingMessage ? .bypassAll : .default,
            touchMessageImmediately: false,
            transaction: transaction
        )
    }

    private func enqueueDownloadOfAttachmentsForNewMessageId(
        _ messageId: String,
        downloadBehavior: AttachmentDownloadBehavior,
        touchMessageImmediately: Bool,
        transaction: SDSAnyWriteTransaction
    ) {
        // If we're not the main app, queue up the download for the next time
        // the main app launches.
        guard CurrentAppContext().isMainApp else {
            Self.pendingNewMessageDownloads.setUInt(
                downloadBehavior.rawValue,
                key: messageId,
                transaction: transaction
            )
            return
        }

        Self.pendingNewMessageDownloads.removeValue(forKey: messageId, transaction: transaction)

        // Don't enqueue the attachment downloads until the write
        // transaction is committed or attachmentDownloads might race
        // and not be able to find the attachment(s)/message/thread.
        transaction.addAsyncCompletionOffMain {
            self.enqueueDownloadOfAttachments(
                forMessageId: messageId,
                attachmentGroup: .allAttachments,
                downloadBehavior: downloadBehavior,
                touchMessageImmediately: touchMessageImmediately
            )
        }
    }

    func enqueueDownloadOfAttachments(
        forMessageId messageId: String,
        attachmentGroup: AttachmentGroup,
        downloadBehavior: AttachmentDownloadBehavior,
        touchMessageImmediately: Bool
    ) {
        Self.serialQueue.async {
            guard !CurrentAppContext().isRunningTests else {
                return
            }
            Self.databaseStorage.read { transaction in
                guard let message = TSMessage.anyFetchMessage(uniqueId: messageId, transaction: transaction) else {
                    return
                }
                let jobRequest = MessageJobRequest(
                    message: message,
                    attachmentGroup: attachmentGroup,
                    downloadBehavior: downloadBehavior,
                    tx: transaction
                )
                guard !jobRequest.isEmpty else {
                    return
                }
                self.enqueueJobs(
                    jobRequest: jobRequest,
                    transaction: transaction
                )

                if touchMessageImmediately {
                    Self.databaseStorage.asyncWrite { transaction in
                        Self.databaseStorage.touch(interaction: message,
                                                   shouldReindex: false,
                                                   transaction: transaction)
                    }
                }

                jobRequest.quotedReplyThumbnailPromise?.done(on: Self.serialQueue) { attachmentStream in
                    Self.updateQuotedMessageThumbnail(
                        messageId: messageId,
                        attachmentStream: attachmentStream
                    )
                }.cauterize()

                let jobCount = jobRequest.jobs.count

                Promise.when(
                    on: Self.serialQueue,
                    fulfilled: jobRequest.jobs.map(\.promise)
                ).done(on: Self.serialQueue) { _ in
                    Logger.debug("Successfully fetched \(jobCount) attachment(s) for message: \(messageId)")
                }.catch(on: Self.serialQueue) { error in
                    Logger.warn("Failed to fetch attachments for message: \(messageId) with error: \(error)")
                }.cauterize()
            }
        }
    }

    func enqueueDownloadOfAttachmentsForNewStoryMessage(_ message: StoryMessage, transaction: SDSAnyWriteTransaction) {
        // No attachment, nothing to do.
        guard message.attachmentUniqueId(tx: transaction) != nil else { return }

        enqueueDownloadOfAttachmentsForNewStoryMessageId(
            message.uniqueId,
            downloadBehavior: message.direction == .outgoing ? .bypassAll : .default,
            touchMessageImmediately: false,
            transaction: transaction
        )
    }

    private func enqueueDownloadOfAttachmentsForNewStoryMessageId(
        _ storyMessageId: String,
        downloadBehavior: AttachmentDownloadBehavior,
        touchMessageImmediately: Bool,
        transaction: SDSAnyWriteTransaction
    ) {
        // If we're not the main app, queue up the download for the next time
        // the main app launches.
        guard CurrentAppContext().isMainApp else {
            Self.pendingNewStoryMessageDownloads.setUInt(
                downloadBehavior.rawValue,
                key: storyMessageId,
                transaction: transaction
            )
            return
        }

        Self.pendingNewStoryMessageDownloads.removeValue(forKey: storyMessageId, transaction: transaction)

        // Don't enqueue the attachment downloads until the write
        // transaction is committed or attachmentDownloads might race
        // and not be able to find the attachment(s)/message/thread.
        transaction.addAsyncCompletionOffMain {
            self.enqueueDownloadOfAttachments(
                forStoryMessageId: storyMessageId,
                downloadBehavior: downloadBehavior,
                touchMessageImmediately: touchMessageImmediately
            )
        }
    }

    @objc
    func enqueueDownloadOfAttachments(
        forStoryMessageId storyMessageId: String,
        downloadBehavior: AttachmentDownloadBehavior,
        touchMessageImmediately: Bool,
        completion: (() -> Void)? = nil
    ) {
        Self.serialQueue.async {
            guard !CurrentAppContext().isRunningTests else {
                return
            }
            Self.databaseStorage.read { transaction in
                guard let message = StoryMessage.anyFetch(uniqueId: storyMessageId, transaction: transaction) else {
                    Logger.warn("Failed to fetch StoryMessage to download attachments")
                    return
                }
                guard
                    let jobRequest = StoryMessageJobRequest(
                        storyMessage: message,
                        downloadBehavior: downloadBehavior,
                        tx: transaction
                    ),
                    !jobRequest.isEmpty
                else {
                    return
                }
                self.enqueueJobs(
                    jobRequest: jobRequest,
                    transaction: transaction
                )

                if touchMessageImmediately {
                    Self.databaseStorage.asyncWrite { transaction in
                        Self.databaseStorage.touch(storyMessage: message, transaction: transaction)
                    }
                }

                Promise.when(
                    on: Self.serialQueue,
                    fulfilled: jobRequest.jobs.map(\.promise)
                ).done(on: Self.serialQueue) { attachmentStreams in
                    Logger.debug("Successfully fetched attachment for StoryMessage: \(storyMessageId)")
                    completion?()
                }.catch(on: Self.serialQueue) { error in
                    Logger.warn("Failed to fetch attachments for StoryMessage: \(storyMessageId) with error: \(error)")
                    completion?()
                }.cauterize()
            }
        }
    }

    @objc
    enum AttachmentGroup: UInt, Equatable {
        case allAttachments
        case bodyAttachments

        var justBodyAttachments: Bool {
            switch self {
            case .allAttachments:
                return false
            case .bodyAttachments:
                return true
            }
        }
    }

    enum AttachmentCategory: UInt, Equatable, CustomStringConvertible {
        case bodyMediaImage
        case bodyMediaVideo
        case bodyAudioVoiceMemo
        case bodyAudioOther
        case bodyFile
        case bodyOversizeText
        case stickerSmall
        case stickerLarge
        case quotedReplyThumbnail
        case linkedPreviewThumbnail
        case contactShareAvatar
        case contactSync

        var isSticker: Bool {
            (self == .stickerSmall || self == .stickerLarge)
        }

        // MARK: - CustomStringConvertible

        public var description: String {
            switch self {
            case .bodyMediaImage:
                return ".bodyMediaImage"
            case .bodyMediaVideo:
                return ".bodyMediaVideo"
            case .bodyAudioVoiceMemo:
                return ".bodyAudioVoiceMemo"
            case .bodyAudioOther:
                return ".bodyAudioOther"
            case .bodyFile:
                return ".bodyFile"
            case .bodyOversizeText:
                return ".bodyOversizeText"
            case .stickerSmall:
                return ".stickerSmall"
            case .stickerLarge:
                return ".stickerLarge"
            case .quotedReplyThumbnail:
                return ".quotedReplyThumbnail"
            case .linkedPreviewThumbnail:
                return ".linkedPreviewThumbnail"
            case .contactShareAvatar:
                return ".contactShareAvatar"
            case .contactSync:
                return ".contactSync"
            default:
                owsFailDebug("unexpected value: \(self.rawValue)")
                return "Unknown"
            }
        }
    }

    private class func updateQuotedMessageThumbnail(
        messageId: String,
        attachmentStream: TSAttachmentStream
    ) {
        Self.databaseStorage.write { transaction in
            guard let message = TSMessage.anyFetchMessage(uniqueId: messageId, transaction: transaction) else {
                Logger.warn("Missing message.")
                return
            }
            guard let thumbnailAttachmentPointerId = message.quotedMessage?.thumbnailAttachmentId,
                  !thumbnailAttachmentPointerId.isEmpty else {
                return
            }
            message.setQuotedMessageThumbnailAttachmentStream(attachmentStream, transaction: transaction)
        }
    }

    private func enqueueJobs(
        jobRequest: JobRequest,
        transaction: SDSAnyReadTransaction
    ) {
        for job in jobRequest.jobs {
            if let attachmentStream = job.loadLatestAttachment(transaction: transaction) as? TSAttachmentStream {
                // If we already have a stream, succeed the job's promise right away.
                job.future.resolve(attachmentStream)
            } else {
                self.enqueueJob(job: job)
            }
        }
    }

    @objc
    static func buildError() -> Error {
        OWSError(error: .attachmentDownloadFailed,
                 description: OWSLocalizedString("ERROR_MESSAGE_ATTACHMENT_DOWNLOAD_FAILED",
                                                comment: "Error message indicating that attachment download(s) failed."),
                 isRetryable: true)
    }

    // MARK: -

    @objc
    static let serialQueue: DispatchQueue = {
        return DispatchQueue(label: "org.signal.attachment.download",
                             qos: .utility,
                             autoreleaseFrequency: .workItem)
    }()

    private func retrieveAttachment(job: Job,
                                    attachmentPointer: TSAttachmentPointer) -> Promise<TSAttachmentStream> {

        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "retrieveAttachment")

        // We want to avoid large downloads from a compromised or buggy service.
        let maxDownloadSize = RemoteConfig.maxAttachmentDownloadSizeBytes

        return firstly(on: Self.serialQueue) { () -> Promise<URL> in
            self.download(
                job: job,
                attachmentPointer: attachmentPointer,
                maxDownloadSizeBytes: maxDownloadSize
            )
        }.then(on: Self.serialQueue) { (encryptedFileUrl: URL) -> Promise<TSAttachmentStream> in
            Self.decrypt(encryptedFileUrl: encryptedFileUrl,
                         attachmentPointer: attachmentPointer)
        }.ensure(on: Self.serialQueue) {
            guard backgroundTask != nil else {
                owsFailDebug("Missing backgroundTask.")
                return
            }
            backgroundTask = nil
        }
    }

    private class DownloadState {
        let job: Job
        let attachmentPointer: TSAttachmentPointer
        let startDate = Date()

        required init(job: Job, attachmentPointer: TSAttachmentPointer) {
            self.job = job
            self.attachmentPointer = attachmentPointer
        }
    }

    private func download(
        job: Job,
        attachmentPointer: TSAttachmentPointer,
        maxDownloadSizeBytes: UInt
    ) -> Promise<URL> {

        let downloadState = DownloadState(job: job, attachmentPointer: attachmentPointer)

        return firstly(on: Self.serialQueue) { () -> Promise<URL> in
            self.downloadAttempt(
                downloadState: downloadState,
                maxDownloadSizeBytes: maxDownloadSizeBytes
            )
        }
    }

    private func downloadAttempt(
        downloadState: DownloadState,
        maxDownloadSizeBytes: UInt,
        resumeData: Data? = nil,
        attemptIndex: UInt = 0
    ) -> Promise<URL> {

        let (promise, future) = Promise<URL>.pending()

        firstly(on: Self.serialQueue) { () -> Promise<OWSUrlDownloadResponse> in
            let attachmentPointer = downloadState.attachmentPointer
            let urlSession = Self.signalService.urlSessionForCdn(cdnNumber: attachmentPointer.cdnNumber)
            let urlPath = try Self.urlPath(for: downloadState)
            let headers: [String: String] = [
                "Content-Type": OWSMimeTypeApplicationOctetStream
            ]

            let progress = { (task: URLSessionTask, progress: Progress) in
                self.handleDownloadProgress(
                    downloadState: downloadState,
                    maxDownloadSizeBytes: maxDownloadSizeBytes,
                    task: task,
                    progress: progress,
                    future: future
                )
            }

            if let resumeData = resumeData {
                let request = try urlSession.endpoint.buildRequest(urlPath, method: .get, headers: headers)
                guard let requestUrl = request.url else {
                    return Promise(error: OWSAssertionError("Request missing url."))
                }
                return urlSession.downloadTaskPromise(requestUrl: requestUrl,
                                                      resumeData: resumeData,
                                                      progress: progress)
            } else {
                return urlSession.downloadTaskPromise(urlPath,
                                                      method: .get,
                                                      headers: headers,
                                                      progress: progress)
            }
        }.map(on: Self.serialQueue) { (response: OWSUrlDownloadResponse) in
            let downloadUrl = response.downloadUrl
            guard let fileSize = OWSFileSystem.fileSize(of: downloadUrl) else {
                throw OWSAssertionError("Could not determine attachment file size.")
            }
            guard fileSize.int64Value <= maxDownloadSizeBytes else {
                throw OWSGenericError("Attachment download length exceeds max size.")
            }
            return downloadUrl
        }.recover(on: Self.serialQueue) { (error: Error) -> Promise<URL> in
            Logger.warn("Error: \(error)")

            let maxAttemptCount = 16
            if error.isNetworkFailureOrTimeout,
               attemptIndex < maxAttemptCount {

                return firstly {
                    // Wait briefly before retrying.
                    Guarantee.after(seconds: 0.25)
                }.then { () -> Promise<URL> in
                    if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                       !resumeData.isEmpty {
                        return self.downloadAttempt(
                            downloadState: downloadState,
                            maxDownloadSizeBytes: maxDownloadSizeBytes,
                            resumeData: resumeData,
                            attemptIndex: attemptIndex + 1
                        )
                    } else {
                        return self.downloadAttempt(
                            downloadState: downloadState,
                            maxDownloadSizeBytes: maxDownloadSizeBytes,
                            attemptIndex: attemptIndex + 1
                        )
                    }
                }
            } else {
                throw error
            }
        }.done(on: Self.serialQueue) { url in
            future.resolve(url)
        }.catch(on: Self.serialQueue) { error in
            future.reject(error)
        }

        return promise
    }

    private class func urlPath(for downloadState: DownloadState) throws -> String {

        let attachmentPointer = downloadState.attachmentPointer
        let urlPath: String
        if attachmentPointer.cdnKey.isEmpty {
            urlPath = String(format: "attachments/%llu", attachmentPointer.serverId)
        } else {
            guard let encodedKey = attachmentPointer.cdnKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw OWSAssertionError("Invalid cdnKey.")
            }
            urlPath = "attachments/\(encodedKey)"
        }
        return urlPath
    }

    private enum AttachmentDownloadError: Error {
        case cancelled
        case oversize
    }

    private func handleDownloadProgress(downloadState: DownloadState,
                                        maxDownloadSizeBytes: UInt,
                                        task: URLSessionTask,
                                        progress: Progress,
                                        future: Future<URL>) {

        guard !self.shouldCancelJob(downloadState: downloadState) else {
            Logger.info("Cancelling job.")
            task.cancel()
            future.reject(AttachmentDownloadError.cancelled)
            return
        }

        // Don't do anything until we've received at least one byte of data.
        guard progress.completedUnitCount > 0 else {
            return
        }

        guard progress.totalUnitCount <= maxDownloadSizeBytes,
              progress.completedUnitCount <= maxDownloadSizeBytes else {
            // A malicious service might send a misleading content length header,
            // so....
            //
            // If the current downloaded bytes or the expected total byes
            // exceed the max download size, abort the download.
            owsFailDebug("Attachment download exceed expected content length: \(progress.totalUnitCount), \(progress.completedUnitCount).")
            task.cancel()
            future.reject(AttachmentDownloadError.oversize)
            return
        }

        downloadState.job.progress = CGFloat(progress.fractionCompleted)

        // Use a slightly non-zero value to ensure that the progress
        // indicator shows up as quickly as possible.
        let progressTheta: Double = 0.001
        Self.fireProgressNotification(progress: max(progressTheta, progress.fractionCompleted),
                                      attachmentId: downloadState.attachmentPointer.uniqueId)
    }

    // MARK: -

    private class func decrypt(encryptedFileUrl: URL,
                               attachmentPointer: TSAttachmentPointer) -> Promise<TSAttachmentStream> {

        // Use serialQueue to ensure that we only load into memory
        // & decrypt a single attachment at a time.
        return firstly(on: Self.serialQueue) { () -> TSAttachmentStream in
            return try autoreleasepool {
                let attachmentStream = databaseStorage.read { transaction in
                    TSAttachmentStream(pointer: attachmentPointer, transaction: transaction)
                }

                guard let originalMediaURL = attachmentStream.originalMediaURL else {
                    throw OWSAssertionError("Missing originalMediaURL.")
                }

                guard let encryptionKey = attachmentPointer.encryptionKey else {
                    throw OWSAssertionError("Missing encryptionKey.")
                }

                try Cryptography.decryptAttachment(
                    at: encryptedFileUrl,
                    metadata: EncryptionMetadata(
                        key: encryptionKey,
                        digest: attachmentPointer.digest,
                        plaintextLength: Int(attachmentPointer.byteCount)
                    ),
                    output: originalMediaURL
                )

                return attachmentStream
            }
        }.ensure(on: Self.serialQueue) {
            do {
                try OWSFileSystem.deleteFileIfExists(url: encryptedFileUrl)
            } catch {
                owsFailDebug("Error: \(error).")
            }
        }
    }

    // MARK: -

    @objc
    static let attachmentDownloadProgressNotification = Notification.Name("AttachmentDownloadProgressNotification")
    @objc
    static var attachmentDownloadProgressKey: String { "attachmentDownloadProgressKey" }
    @objc
    static var attachmentDownloadAttachmentIDKey: String { "attachmentDownloadAttachmentIDKey" }

    private class func fireProgressNotification(progress: Double, attachmentId: AttachmentId) {
        NotificationCenter.default.postNotificationNameAsync(attachmentDownloadProgressNotification,
                                                             object: nil,
                                                             userInfo: [
                                                                attachmentDownloadProgressKey: NSNumber(value: progress),
                                                                attachmentDownloadAttachmentIDKey: attachmentId
                                                             ])
    }
}
