//
//  WebRTC.m
//  Copyright (c) 2014 &yet, LLC and WebRTC contributors
//

#import "WebRTC.h"

#import <AVFoundation/AVFoundation.h>


#import "RTCPeerConnection.h"
#import "RTCICEServer.h"
#import "RTCPair.h"
#import "RTCMediaConstraints.h"
#import "RTCSessionDescription.h"
#import "RTCSessionDescriptionDelegate.h"
#import "RTCPeerConnectionDelegate.h"

#import "RTCAudioTrack.h"
#import "RTCAVFoundationVideoSource.h"
#import "RTCVideoTrack.h"

@interface WebRTC () <
    RTCSessionDescriptionDelegate,
    RTCPeerConnectionDelegate>




@property (nonatomic, strong) NSMutableDictionary *peerConnections;
@property (nonatomic, strong) NSMutableDictionary *peerToRoleMap;
@property (nonatomic, strong) NSMutableDictionary *peerToICEMap;

@property (nonatomic) BOOL allowVideo;
@property (nonatomic, strong) AVCaptureDevice *videoDevice;

@property (nonatomic, strong) NSMutableArray *iceServers;

@end

static NSString * const PeerConnectionRoleInitiator = @"PeerConnectionRoleInitiator";
static NSString * const PeerConnectionRoleReceiver = @"PeerConnectionRoleReceiver";
static NSString * const WebRTCSTUNHostname = @"stun:23.21.150.121";

@implementation WebRTC

#pragma mark - object lifecycle

- (instancetype)initWithVideoDevice:(AVCaptureDevice *)device {
	self = [super init];
	if (self) {
		if (device) {
			_allowVideo = YES;
			_videoDevice = device;
		}
		[self _commonSetup];
	}
	return self;
}

- (instancetype)initWithVideo:(BOOL)allowVideo {
	// Set front camera as the default device
	AVCaptureDevice* frontCamera;
	if (allowVideo) {
		frontCamera = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] lastObject];
	}
    
	return [self initWithVideoDevice:frontCamera];
}

- (instancetype)init {
	return [self initWithVideo:YES];
}

- (void)_commonSetup {
    _peerFactory = [[RTCPeerConnectionFactory alloc] init];
    _peerConnections = [NSMutableDictionary dictionary];
    _peerToRoleMap = [NSMutableDictionary dictionary];
    _peerToICEMap = [NSMutableDictionary dictionary];

    self.iceServers = [NSMutableArray new];
    RTCICEServer *defaultStunServer = [[RTCICEServer alloc] initWithURI:[NSURL URLWithString:WebRTCSTUNHostname] username:@"" password:@""];
       RTCICEServer *server = [[RTCICEServer alloc] initWithURI:[NSURL URLWithString:@"stun:stun.l.google.com:19302"] username:@"" password:@""];
    
    [self.iceServers addObject:server];
    [self.iceServers addObject:defaultStunServer];
    [RTCPeerConnectionFactory initializeSSL];

    [self _createLocalStream];
}

- (void)_createLocalStream {
    
    self.localMediaStream = [self.peerFactory mediaStreamWithLabel:@"ARDAMS"];

    RTCAudioTrack *audioTrack = [self.peerFactory audioTrackWithID:@"ARDAMSa0"];
    [self.localMediaStream addAudioTrack:audioTrack];

    if (self.allowVideo) {
        RTCAVFoundationVideoSource *videoSource = [[RTCAVFoundationVideoSource alloc] initWithFactory:self.peerFactory constraints:nil];
        videoSource.useBackCamera = NO;
        RTCVideoTrack *videoTrack = [[RTCVideoTrack alloc] initWithFactory:self.peerFactory source:videoSource trackId:@"ARDAMSv0"];
        [self.localMediaStream addVideoTrack:videoTrack];
    }

}

- (RTCMediaConstraints *)_mediaConstraints {
    RTCPair *audioConstraint = [[RTCPair alloc] initWithKey:@"OfferToReceiveAudio" value:@"true"];
    RTCPair *videoConstraint = [[RTCPair alloc] initWithKey:@"OfferToReceiveVideo" value:@"true"];

    return [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@[audioConstraint, videoConstraint] optionalConstraints:nil];
}

#pragma mark - ICE server

- (void)addICEServer:(RTCICEServer *)server {
    BOOL isStun = [server.URI.scheme isEqualToString:@"stun"];
    if (isStun) {
        [self.iceServers replaceObjectAtIndex:0 withObject:server];
    }
    else {
        [self.iceServers addObject:server];
    }
}

#pragma mark - Peer Connections

- (NSString *)identifierForPeer:(RTCPeerConnection *)peer {
    NSArray *keys = [self.peerConnections allKeysForObject:peer];
    return (keys.count == 0) ? nil : keys[0];
}

- (void)addPeerConnectionForID:(NSString *)identifier {
    RTCPeerConnection *peer = [self.peerFactory peerConnectionWithICEServers:[self iceServers] constraints:[self _mediaConstraints] delegate:self];
    [peer addStream:self.localMediaStream];
    [self.peerConnections setObject:peer forKey:identifier];
}

- (void)removePeerConnectionForID:(NSString *)identifier {
    RTCPeerConnection* peer = self.peerConnections[identifier];
    [self.peerConnections removeObjectForKey:identifier];
    [self.peerToRoleMap removeObjectForKey:identifier];
    [peer close];
}

#pragma mark -

- (void)createOfferForPeerWithID:(NSString *)peerID {
    RTCPeerConnection *peerConnection = [self.peerConnections objectForKey:peerID];
    [self.peerToRoleMap setObject:PeerConnectionRoleInitiator forKey:peerID];
    [peerConnection createOfferWithDelegate:self constraints:[self _mediaConstraints]];
}

- (void)setRemoteDescription:(RTCSessionDescription *)remoteSDP forPeerWithID:(NSString *)peerID receiver:(BOOL)isReceiver {
    RTCPeerConnection *peerConnection = [self.peerConnections objectForKey:peerID];
    if (isReceiver) {
        [self.peerToRoleMap setObject:PeerConnectionRoleReceiver forKey:peerID];
    }
    [peerConnection setRemoteDescriptionWithDelegate:self sessionDescription:remoteSDP];
}

- (void)addICECandidate:(RTCICECandidate*)candidate forPeerWithID:(NSString *)peerID {
    RTCPeerConnection *peerConnection = [self.peerConnections objectForKey:peerID];
    if (peerConnection.iceGatheringState == RTCICEGatheringNew) {
        NSMutableArray *candidates = [self.peerToICEMap objectForKey:peerID];
        if (!candidates) {
            candidates = [NSMutableArray array];
            [self.peerToICEMap setObject:candidates forKey:peerID];
        }
        
            [candidates addObject:candidate];
        
    } else {
        [peerConnection addICECandidate:candidate];
    }
}

#pragma mark - RTCSessionDescriptionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didCreateSessionDescription:(RTCSessionDescription *)sdp error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        RTCSessionDescription* sessionDescription = [[RTCSessionDescription alloc] initWithType:sdp.type sdp:sdp.description];
        [peerConnection setLocalDescriptionWithDelegate:self sessionDescription:sessionDescription];
    });
}




- (void)peerConnection:(RTCPeerConnection *)peerConnection didSetSessionDescriptionWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (peerConnection.iceGatheringState == RTCICEGatheringGathering) {
            NSArray *keys = [self.peerConnections allKeysForObject:peerConnection];
            if ([keys count] > 0) {
                NSArray *candidates = [self.peerToICEMap objectForKey:keys[0]];
                for (RTCICECandidate* candidate in candidates) {
                    [peerConnection addICECandidate:candidate];
                }
                [self.peerToICEMap removeObjectForKey:keys[0]];
            }
        }

        if (peerConnection.signalingState == RTCSignalingHaveLocalOffer) {
            NSArray *keys = [self.peerConnections allKeysForObject:peerConnection];
            if ([keys count] > 0) {
                [self.delegate webRTC:self didSendSDPOffer:peerConnection.localDescription forPeerWithID:keys[0]];
            }
        } else if (peerConnection.signalingState == RTCSignalingHaveRemoteOffer) {
            [peerConnection createAnswerWithDelegate:self constraints:[self _mediaConstraints]];
        } else if (peerConnection.signalingState == RTCSignalingStable) {
            NSArray* keys = [self.peerConnections allKeysForObject:peerConnection];
            if ([keys count] > 0) {
                NSString* role = [self.peerToRoleMap objectForKey:keys[0]];
                if (role == PeerConnectionRoleReceiver) {
                    [self.delegate webRTC:self didSendSDPAnswer:peerConnection.localDescription forPeerWithID:keys[0]];
                }
            }
        }
    });
}

#pragma mark - String utilities

- (NSString *)stringForSignalingState:(RTCSignalingState)state {
    NSString *signalingStateString = nil;
    switch (state) {
        case RTCSignalingStable:
            signalingStateString = @"Stable";
            break;
        case RTCSignalingHaveLocalOffer:
            signalingStateString = @"Have Local Offer";
            break;
        case RTCSignalingHaveRemoteOffer:
            signalingStateString = @"Have Remote Offer";
            break;
        case RTCSignalingClosed:
            signalingStateString = @"Closed";
            break;
        default:
            signalingStateString = @"Other state";
            break;
    }

    return signalingStateString;
}

- (NSString *)stringForConnectionState:(RTCICEConnectionState)state {
    NSString *connectionStateString = nil;
    switch (state) {
        case RTCICEConnectionNew:
            connectionStateString = @"New";
            break;
        case RTCICEConnectionChecking:
            connectionStateString = @"Checking";
            break;
        case RTCICEConnectionConnected:
            connectionStateString = @"Connected";
            break;
        case RTCICEConnectionCompleted:
            connectionStateString = @"Completed";
            break;
        case RTCICEConnectionFailed:
            connectionStateString = @"Failed";
            break;
        case RTCICEConnectionDisconnected:
            connectionStateString = @"Disconnected";
            break;
        case RTCICEConnectionClosed:
            connectionStateString = @"Closed";
            break;
        default:
            connectionStateString = @"Other state";
            break;
    }
    return connectionStateString;
}

- (NSString *)stringForGatheringState:(RTCICEGatheringState)state {
    NSString *gatheringState = nil;
    switch (state) {
        case RTCICEGatheringNew:
            gatheringState = @"New";
            break;
        case RTCICEGatheringGathering:
            gatheringState = @"Gathering";
            break;
        case RTCICEGatheringComplete:
            gatheringState = @"Complete";
            break;
        default:
            gatheringState = @"Other state";
            break;
    }
    return gatheringState;
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnectionOnError:(RTCPeerConnection *)peerConnection {

}

- (void)peerConnection:(RTCPeerConnection *)peerConnection signalingStateChanged:(RTCSignalingState)stateChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection addedStream:(RTCMediaStream *)stream {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate webRTC:self addedStream:stream forPeerWithID:[self identifierForPeer:peerConnection]];
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection removedStream:(RTCMediaStream *)stream {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate webRTC:self removedStream:stream forPeerWithID:[self identifierForPeer:peerConnection]];
    });
}

- (void)peerConnectionOnRenegotiationNeeded:(RTCPeerConnection *)peerConnection {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"peerConnectionOnRenegotiationNeeded ?");
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection iceConnectionChanged:(RTCICEConnectionState)newState {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate webRTC:self didObserveICEConnectionStateChange:newState forPeerWithID:[self identifierForPeer:peerConnection]];
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection iceGatheringChanged:(RTCICEGatheringState)newState {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"peerConnection iceGatheringChanged?");
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection gotICECandidate:(RTCICECandidate *)candidate {
    dispatch_async(dispatch_get_main_queue(), ^{

        NSArray* keys = [self.peerConnections allKeysForObject:peerConnection];
        if ([keys count] > 0) {
            [self.delegate webRTC:self didSendICECandidate:candidate forPeerWithID:keys[0]];
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"peerConnection didOpenDataChannel?");
    });
}

@end
