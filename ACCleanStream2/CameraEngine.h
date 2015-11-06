//
//  CameraEngine.h
//  ACStreamClean
//
//  Created by Andrew Cavanagh on 3/29/15.
//  Copyright (c) 2015 Andrew Cavanagh. All rights reserved.
//

#import <Foundation/Foundation.h>
@import AVFoundation;
@import VideoToolbox;

@protocol CameraEngineDelegateProtocol <NSObject>
- (void)didCompressFrameToH264SampleBuffer:(NSData *)data sampleBuffer:(CMSampleBufferRef)sampleBufferRef;
@end

@interface CameraEngine : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<CameraEngineDelegateProtocol> delegate;
+ (instancetype)sharedInstance;
- (void)start;
- (void)stop;
@end
