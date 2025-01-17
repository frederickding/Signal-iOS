//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalMessaging

extension TSOutgoingMessage {
    @objc
    class func prepareForMultisending(
        destinations: [MultisendDestination],
        state: MultisendState,
        transaction: SDSAnyWriteTransaction
    ) throws {
        for destination in destinations {
            // If this thread has a pending message request, treat it as accepted.
            ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequest(
                destination.thread,
                setDefaultTimerIfNecessary: true,
                tx: transaction
            )

            let messageBodyForContext = state.approvalMessageBody?.forForwarding(
                to: destination.thread,
                transaction: transaction.unwrapGrdbRead
            ).asMessageBodyForForwarding()

            let message: TSOutgoingMessage
            let attachmentUUIDs: [UUID]
            switch destination.content {
            case .media(let attachments):
                attachmentUUIDs = attachments.map(\.id)
                message = try ThreadUtil.createUnsentMessage(
                    body: messageBodyForContext,
                    mediaAttachments: attachments.map(\.value),
                    thread: destination.thread,
                    transaction: transaction
                )

            case .text:
                owsFailDebug("Cannot send TextAttachment to chats.")
                continue
            }

            state.messages.append(message)
            state.threads.append(destination.thread)

            for (idx, attachmentId) in message.bodyAttachmentIds(with: transaction).enumerated() {
                let attachmentUUID = attachmentUUIDs[idx]
                var correspondingIdsForAttachment = state.correspondingAttachmentIds[attachmentUUID] ?? []
                correspondingIdsForAttachment += [attachmentId]
                state.correspondingAttachmentIds[attachmentUUID] = correspondingIdsForAttachment
            }

            destination.thread.donateSendMessageIntent(for: message, transaction: transaction)
        }
    }
}
