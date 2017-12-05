//
//  OTRXMPPMessageYapStroage.m
//  ChatSecure
//
//  Created by David Chiles on 8/13/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "OTRXMPPMessageYapStorage.h"
@import XMPPFramework;
#import "OTRLog.h"
@import OTRKit;
#import "OTRXMPPBuddy.h"
#import "OTRIncomingMessage.h"
#import "OTROutgoingMessage.h"
#import "OTRAccount.h"
#import "OTRConstants.h"
#import <ChatSecureCore/ChatSecureCore-Swift.h>
#import "OTRThreadOwner.h"
#import "OTRBuddyCache.h"
#import "OTRXMPPError.h"
#import "OTRXMPPManager_Private.h"

@implementation OTRXMPPMessageYapStorage

- (instancetype)initWithDatabaseConnection:(YapDatabaseConnection *)connection
{
    if (self = [self init]) {
        _databaseConnection = connection;
        _moduleDelegateQueue = dispatch_queue_create("OTRXMPPMessageYapStroage-delegateQueue", 0);
    }
    return self;
}


- (OTRXMPPBuddy *)buddyForJID:(XMPPJID *)jid stream:(XMPPStream *)stream transaction:(YapDatabaseReadTransaction *)transaction
{
    NSParameterAssert(jid);
    NSParameterAssert(stream.tag);
    NSParameterAssert(transaction);
    if (!stream.tag || !jid || !transaction) { return nil; }
    return [OTRXMPPBuddy fetchBuddyWithJid:jid accountUniqueId:stream.tag transaction:transaction];
}

- (OTRBaseMessage *)baseMessageFromXMPPMessage:(XMPPMessage *)xmppMessage buddyId:(NSString *)buddyId class:(Class)class {
    NSString *body = [xmppMessage body];
    
    NSDate * date = [xmppMessage delayedDeliveryDate];
    
    OTRBaseMessage *message = [[class alloc] init];
    message.text = body;
    message.buddyUniqueId = buddyId;
    if (date) {
        message.date = date;
    }
    
    message.messageId = [xmppMessage elementID];
    return message;
}

- (OTROutgoingMessage *)outgoingMessageFromXMPPMessage:(XMPPMessage *)xmppMessage buddyId:(NSString *)buddyId {
    OTROutgoingMessage *outgoingMessage = (OTROutgoingMessage *)[self baseMessageFromXMPPMessage:xmppMessage buddyId:buddyId class:[OTROutgoingMessage class]];
    // Fill in current data so it looks like this 'outgoing' message was really sent (but of course this is a message we received through carbons).
    outgoingMessage.dateSent = [NSDate date];
    return outgoingMessage;
}

- (OTRIncomingMessage *)incomingMessageFromXMPPMessage:(XMPPMessage *)xmppMessage buddyId:(NSString *)buddyId
{
    return (OTRIncomingMessage *)[self baseMessageFromXMPPMessage:xmppMessage buddyId:buddyId class:[OTRIncomingMessage class]];
}

- (void)xmppStream:(XMPPStream *)stream didReceiveMessage:(XMPPMessage *)xmppMessage
{
    // We don't handle incoming group chat messages here
    // Check out OTRXMPPRoomYapStorage instead
    if ([[xmppMessage type] isEqualToString:@"groupchat"] ||
        [xmppMessage elementForName:@"x" xmlns:XMPPMUCUserNamespace] ||
        [xmppMessage elementForName:@"x" xmlns:@"jabber:x:conference"]) {
        return;
    }
    // We handle carbons elsewhere via XMPPMessageCarbonsDelegate
    // We handle MAM elsewhere as well
    if (xmppMessage.isMessageCarbon ||
        xmppMessage.mamResult) {
        return;
    }
    
    [self.databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        if (![stream.tag isKindOfClass:[NSString class]]) {
            DDLogError(@"Error - No account tag on stream %@", stream);
            return;
        }
        NSString *accountId = stream.tag;
        NSString *username = [[xmppMessage from] bare];
        XMPPJID *fromJID = xmppMessage.from;
        if (!fromJID) {
            DDLogWarn(@"No from for message: %@", xmppMessage);
            return;
        }
        OTRXMPPAccount *account = [OTRXMPPAccount fetchObjectWithUniqueID:accountId transaction:transaction];
        if (!account) {
            DDLogWarn(@"No account for message: %@", xmppMessage);
            return;
        }
        OTRXMPPBuddy *messageBuddy = [self buddyForJID:fromJID stream:stream transaction:transaction];
        if (!messageBuddy) {
            // message from server
            
            DDLogWarn(@"No buddy for message: %@", xmppMessage);
            return;
        }
        [self handleChatState:xmppMessage fromJID:fromJID stream:stream transaction:transaction];
        [self handleDeliverResponse:xmppMessage transaction:transaction];
        
        // If we receive a message from an online buddy that counts as them interacting with us
        OTRThreadStatus status = [OTRBuddyCache.shared threadStatusForBuddy:messageBuddy];
        if (status != OTRThreadStatusOffline &&
            ![xmppMessage hasReceiptResponse] &&
            ![xmppMessage isErrorMessage]) {
            [OTRBuddyCache.shared setLastSeenDate:[NSDate date] forBuddy:messageBuddy];
        }
        
        // Check if this is a bounced outgoing message / error
        NSString *eid = [xmppMessage elementID];
        if (eid && [xmppMessage isErrorMessage]) {
            id<OTRMessageProtocol> existingMessage = [OTROutgoingMessage messageForMessageId:eid transaction:transaction];            
            if ([existingMessage isKindOfClass:[OTROutgoingMessage class]]) {
                OTROutgoingMessage *message = (OTROutgoingMessage*)existingMessage;
                message.error = [OTRXMPPError errorForXMLElement:xmppMessage];
                [message saveWithTransaction:transaction];
            } else if ([existingMessage isKindOfClass:[OTRIncomingMessage class]]) {
                NSString *errorText = [[xmppMessage elementForName:@"error"] elementForName:@"text"].stringValue;
                if ([errorText containsString:@"OTR Error"]) {
                    // automatically renegotiate a new session when there's an error
                    [[OTRProtocolManager sharedInstance].encryptionManager.otrKit initiateEncryptionWithUsername:username accountName:account.username protocol:account.protocolTypeString];
                }
            }
            return;
        }

        OTRIncomingMessage *message = [self incomingMessageFromXMPPMessage:xmppMessage buddyId:messageBuddy.uniqueId];
        NSString *activeThreadYapKey = [[OTRAppDelegate appDelegate] activeThreadYapKey];
        if([activeThreadYapKey isEqualToString:message.threadId]) {
            message.read = YES;
        }
        
        // Extract XEP-0359 stanza-id
        NSString *originId = xmppMessage.originId;
        NSString *stanzaId = @"";// [xmppMessage extractStanzaIdWithAccount:account capabilities:self.capabilities];
        message.originId = originId;
        message.stanzaId = stanzaId;
        
        if ([self isDuplicateMessage:xmppMessage stanzaId:stanzaId buddyUniqueId:messageBuddy.uniqueId transaction:transaction]) {
            DDLogWarn(@"Duplicate message received: %@", xmppMessage);
            return;
        }
        
        if (message.text) {
            [[OTRProtocolManager sharedInstance].encryptionManager.otrKit decodeMessage:message.text username:messageBuddy.username accountName:account.username protocol:kOTRProtocolTypeXMPP tag:message];
        }
    }];
}

- (void)handleChatState:(XMPPMessage *)xmppMessage fromJID:(XMPPJID *)fromJID stream:(XMPPStream *)stream transaction:(YapDatabaseReadTransaction *)transaction
{
    // Saves aren't needed when setting chatState or status because OTRBuddyCache is used internally

    OTRXMPPBuddy *messageBuddy = [self buddyForJID:fromJID stream:stream transaction:transaction];
    if (!messageBuddy) { return; }
    OTRChatState chatState = OTRChatStateUnknown;
    if([xmppMessage hasChatState])
    {
        if([xmppMessage hasComposingChatState])
            chatState = OTRChatStateComposing;
        else if([xmppMessage hasPausedChatState])
            chatState = OTRChatStatePaused;
        else if([xmppMessage hasActiveChatState])
            chatState = OTRChatStateActive;
        else if([xmppMessage hasInactiveChatState])
            chatState = OTRChatStateInactive;
        else if([xmppMessage hasGoneChatState])
            chatState = OTRChatStateGone;
    }
    [OTRBuddyCache.shared setChatState:chatState forBuddy:messageBuddy];
}

- (void)handleDeliverResponse:(XMPPMessage *)xmppMessage transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    if ([xmppMessage hasReceiptResponse] && ![xmppMessage isErrorMessage]) {
        [OTROutgoingMessage receivedDeliveryReceiptForMessageId:[xmppMessage receiptResponseID] transaction:transaction];
    }
}

/** It is a violation of the XMPP spec to discard messages with duplicate stanza elementIds. We must use XEP-0359 stanza-id only. */
- (BOOL)isDuplicateMessage:(XMPPMessage *)message stanzaId:(NSString*)stanzaId buddyUniqueId:(NSString *)buddyUniqueId transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    __block BOOL result = NO;
    if (!stanzaId.length) {
        return NO;
    }

    [transaction enumerateMessagesWithElementId:nil originId:nil stanzaId:stanzaId block:^(id<OTRMessageProtocol> _Nonnull databaseMessage, BOOL * _Null_unspecified stop) {
        if ([[databaseMessage threadId] isEqualToString:buddyUniqueId]) {
            *stop = YES;
            result = YES;
        }
    }];
    return result;
}

/// Handles both Carbons and MAM
- (void)handleForwardedMessage:(XMPPMessage *)forwardedMessage delayedDeliveryDate:(nullable NSDate*)delayedDeliveryDate stream:(XMPPStream *)stream outgoing:(BOOL)isOutgoing
{
    if (!forwardedMessage.isMessageWithBody ||
        forwardedMessage.isErrorMessage ||
        [OTRKit stringStartsWithOTRPrefix:forwardedMessage.body]) {
        DDLogWarn(@"Discarding forwarded message: %@", forwardedMessage.prettyXMLString);
        return;
    }
    //Sent Message Carbons are sent by our account to another
    //So from is our JID and to is buddy
    BOOL incoming = !isOutgoing;
    
    
    XMPPJID *jid = nil;
    if (incoming) {
        jid = forwardedMessage.from;
    } else {
        jid = forwardedMessage.to;
    }
    if (!jid) { return; }
    NSString *accountId = stream.tag;
    if (!accountId.length) { return; }
    
    [self.databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * __nonnull transaction) {
        OTRXMPPAccount *account = [OTRXMPPAccount fetchObjectWithUniqueID:accountId transaction:transaction];
        OTRXMPPBuddy *buddy = [self buddyForJID:jid stream:stream transaction:transaction];
        if (!buddy || !account) {
            return;
        }
        // Extract XEP-0359 stanza-id
        NSString *originId = forwardedMessage.originId;
        NSString *stanzaId = @"";// [forwardedMessage extractStanzaIdWithAccount:account];

        if (incoming) {
            [self handleChatState:forwardedMessage fromJID:jid stream:stream transaction:transaction];
            [self handleDeliverResponse:forwardedMessage transaction:transaction];
        }
        
        if ([self isDuplicateMessage:forwardedMessage stanzaId:stanzaId buddyUniqueId:buddy.uniqueId transaction:transaction]) {
            DDLogWarn(@"Duplicate message received: %@", forwardedMessage);
            return;
        }
        OTRBaseMessage *message = nil;
        if (incoming) {
            OTRIncomingMessage *incomingMessage = [self incomingMessageFromXMPPMessage:forwardedMessage buddyId:buddy.uniqueId];
            NSString *activeThreadYapKey = [[OTRAppDelegate appDelegate] activeThreadYapKey];
            if([activeThreadYapKey isEqualToString:message.threadId]) {
                incomingMessage.read = YES;
            }
            message = incomingMessage;
        } else {
            message = [self outgoingMessageFromXMPPMessage:forwardedMessage buddyId:buddy.uniqueId];
        }
        if (delayedDeliveryDate) {
            message.date = delayedDeliveryDate;
        }
        message.originId = originId;
        message.stanzaId = stanzaId;
        [message saveWithTransaction:transaction];
    }];
}

#pragma mark - XMPPMessageCarbonsDelegate

- (void)xmppMessageCarbons:(XMPPMessageCarbons *)xmppMessageCarbons willReceiveMessage:(XMPPMessage *)message outgoing:(BOOL)isOutgoing { }

- (void)xmppMessageCarbons:(XMPPMessageCarbons *)xmppMessageCarbons didReceiveMessage:(XMPPMessage *)message outgoing:(BOOL)isOutgoing
{
    [self handleForwardedMessage:message delayedDeliveryDate:nil stream:xmppMessageCarbons.xmppStream outgoing:isOutgoing];
}

#pragma mark - XMPPMessageArchiveManagementDelegate

- (void)xmppMessageArchiveManagement:(XMPPMessageArchiveManagement *)xmppMessageArchiveManagement didFinishReceivingMessagesWithSet:(XMPPResultSet *)resultSet {
    DDLogVerbose(@"MAM didFinishReceivingMessagesWithSet: %@", resultSet.prettyXMLString);
}
- (void)xmppMessageArchiveManagement:(XMPPMessageArchiveManagement *)xmppMessageArchiveManagement didReceiveMAMMessage:(XMPPMessage *)message {
    DDLogVerbose(@"MAM didReceiveMAMMessage: %@", message.prettyXMLString);
    NSXMLElement *result = message.mamResult;
    XMPPMessage *forwardedMessage = result.forwardedMessage;
    if (!forwardedMessage) { return; }
    NSDate *delayedDeliveryDate = result.forwardedStanzaDelayedDeliveryDate;
    XMPPJID *fromJID = forwardedMessage.from;
    if (!fromJID) { return; }
    BOOL isOutgoing = [fromJID isEqualToJID:xmppMessageArchiveManagement.xmppStream.myJID options:XMPPJIDCompareBare];
    [self handleForwardedMessage:forwardedMessage delayedDeliveryDate:delayedDeliveryDate stream:xmppMessageArchiveManagement.xmppStream outgoing:isOutgoing];
}
- (void)xmppMessageArchiveManagement:(XMPPMessageArchiveManagement *)xmppMessageArchiveManagement didFailToReceiveMessages:(XMPPIQ *)error {
    DDLogError(@"MAM didFailToReceiveMessages: %@", error.prettyXMLString);
}

- (void)xmppMessageArchiveManagement:(XMPPMessageArchiveManagement *)xmppMessageArchiveManagement didReceiveFormFields:(XMPPIQ *)iq {
    DDLogVerbose(@"MAM didReceiveFormFields: %@", iq.prettyXMLString);
}
- (void)xmppMessageArchiveManagement:(XMPPMessageArchiveManagement *)xmppMessageArchiveManagement didFailToReceiveFormFields:(XMPPIQ *)iq {
    DDLogError(@"MAM didFailToReceiveFormFields: %@", iq.prettyXMLString);
}

@end