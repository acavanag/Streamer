//
//  CameraEngine.m
//  ACStreamClean
//
//  Created by Andrew Cavanagh on 3/29/15.
//  Copyright (c) 2015 Andrew Cavanagh. All rights reserved.
//

#import "CameraEngine.h"
#import <mach/mach_time.h>

#define AUDIO_ON 1
#define VIDEO_ON 0

//static const uint8_t kStartCode[] = {0x00, 0x00, 0x00, 0x01};

NSString * const naluTypesStrings[] = {
    @"Unspecified (non-VCL)",
    @"Coded slice of a non-IDR picture (VCL)",
    @"Coded slice data partition A (VCL)",
    @"Coded slice data partition B (VCL)",
    @"Coded slice data partition C (VCL)",
    @"Coded slice of an IDR picture (VCL)",
    @"Supplemental enhancement information (SEI) (non-VCL)",
    @"Sequence parameter set (non-VCL)",
    @"Picture parameter set (non-VCL)",
    @"Access unit delimiter (non-VCL)",
    @"End of sequence (non-VCL)",
    @"End of stream (non-VCL)",
    @"Filler data (non-VCL)",
    @"Sequence parameter set extension (non-VCL)",
    @"Prefix NAL unit (non-VCL)",
    @"Subset sequence parameter set (non-VCL)",
    @"Reserved (non-VCL)",
    @"Reserved (non-VCL)",
    @"Reserved (non-VCL)",
    @"Coded slice of an auxiliary coded picture without partitioning (non-VCL)",
    @"Coded slice extension (non-VCL)",
    @"Coded slice extension for depth view components (non-VCL)",
    @"Reserved (non-VCL)",
    @"Reserved (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
};

@interface CameraEngine ()
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic) VTCompressionSessionRef compressionSession;

@property (nonatomic) double firstFrameTime;
@property (nonatomic) unsigned long long frameCount;
@property (nonatomic) double frameTime;
@property (nonatomic) double lastFrameTime;
@property (nonatomic) mach_timebase_info_data_t mach_timebase;

@property (nonatomic) CMFormatDescriptionRef formatDescription;

@property (nonatomic, weak) AVCaptureOutput *videoOutput;
@property (nonatomic, weak) AVCaptureOutput *audioOutput;
@end

@implementation CameraEngine

+ (instancetype)sharedInstance
{
    static CameraEngine *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[CameraEngine alloc] init];
    });
    return sharedInstance;
}

- (void)start
{
    if (self.session) {
        return;
    }

    NSError *error = nil;
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    session.sessionPreset = AVCaptureSessionPreset640x480;
    
    mach_timebase_info(&_mach_timebase);
    
    #ifdef VIDEO_ON
    NSDictionary *encoderSpec = @{ @"RequireHardwareAcceleratedVideoEncoder": @YES };
    OSStatus s = VTCompressionSessionCreate(NULL, 640, 480, kCMVideoCodecType_H264, (__bridge CFDictionaryRef)encoderSpec, NULL, NULL, VideoCompressorReceiveFrame, (__bridge void *)(self), &_compressionSession);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_compressionSession, (__bridge CFStringRef)@"RealTime", kCFBooleanTrue);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel, (__bridge CFStringRef)@"H264_Baseline_AutoLevel");
    
    if (s != 0) {
        NSLog(@"lulz no: %d", (int)s);
    }
    
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    [session addInput:videoInput];
    [session addOutput:videoOutput];
    
    dispatch_queue_t videoQueue = dispatch_queue_create("videoQueue", NULL);
    [videoOutput setSampleBufferDelegate:self queue:videoQueue];
    videoOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : [NSNumber numberWithInt:kCVPixelFormatType_32BGRA]};
    self.videoOutput = videoOutput;
    #endif
    
    #ifdef AUDIO_ON
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
    AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [session addInput:audioInput];
    [session addOutput:audioOutput];
    
    dispatch_queue_t audioQueue = dispatch_queue_create("audioQueue", NULL);
    [audioOutput setSampleBufferDelegate:self queue:audioQueue];
    self.audioOutput = audioOutput;
    #endif
    
    if (error) {
        NSLog(@"%@", error.description);
    }
    
    [session startRunning];
    self.session = session;
}

static void VideoCompressorReceiveFrame(void *outputCallbackRefCon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTEncodeInfoFlags infoFlags,
                                        CMSampleBufferRef sampleBuffer) {
    
    CameraEngine *_self = (__bridge CameraEngine *)sourceFrameRefCon;
    
    if (status != noErr) {
        NSLog(@"Error encoding video, err=%lld", (int64_t)status);
        return;
    }
    
    NSMutableData *elementaryStream = [NSMutableData data];
    
    BOOL isIFrame = NO;
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, 0);
    if (CFArrayGetCount(attachmentsArray)) {
        CFBooleanRef notSync;
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachmentsArray, 0);
        BOOL keyExists = CFDictionaryGetValueIfPresent(dict,
                                                       kCMSampleAttachmentKey_NotSync,
                                                       (const void **)&notSync);
        isIFrame = !keyExists || !CFBooleanGetValue(notSync);
    }
    
    static const size_t startCodeLength = 4;
    static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
    
    if (isIFrame) {
        CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
        _self.formatDescription = description;
        size_t numberOfParameterSets;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,
                                                           0, NULL, NULL,
                                                           &numberOfParameterSets,
                                                           NULL);
        
        for (int i = 0; i < numberOfParameterSets; i++) {
            const uint8_t *parameterSetPointer;
            size_t parameterSetLength;
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,
                                                               i,
                                                               &parameterSetPointer,
                                                               &parameterSetLength,
                                                               NULL, NULL);
            
            [elementaryStream appendBytes:startCode length:startCodeLength];
            [elementaryStream appendBytes:parameterSetPointer length:parameterSetLength];
        }
    }
    
    size_t blockBufferLength;
    uint8_t *bufferDataPointer = NULL;
    CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sampleBuffer),
                                0,
                                NULL,
                                &blockBufferLength,
                                (char **)&bufferDataPointer);
    
    size_t bufferOffset = 0;
    static const int AVCCHeaderLength = 4;
    while (bufferOffset < blockBufferLength - AVCCHeaderLength) {
        uint32_t NALUnitLength = 0;
        memcpy(&NALUnitLength, bufferDataPointer + bufferOffset, AVCCHeaderLength);
        NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
        [elementaryStream appendBytes:startCode length:startCodeLength];
        [elementaryStream appendBytes:bufferDataPointer + bufferOffset + AVCCHeaderLength
                               length:NALUnitLength];
        bufferOffset += AVCCHeaderLength + NALUnitLength;
    }

    [_self handleElementaryStream:elementaryStream];
}

static void ReceiveAudioBuffer(void *sourceFrameRefCon, CMSampleBufferRef sampleBuffer)
{
    CameraEngine *_self = (__bridge CameraEngine *)sourceFrameRefCon;
    
    CFRetain(sampleBuffer);
    
    AudioBufferList audioBufferList;
    CMBlockBufferRef blockBuffer;
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, &audioBufferList, sizeof(audioBufferList), NULL, NULL, 0, &blockBuffer);
    
    NSMutableData *data = [[NSMutableData alloc] init];
    for (int i = 0; i < audioBufferList.mNumberBuffers; i++) {
        AudioBuffer audioBuffer = audioBufferList.mBuffers[i];
        Float32 *frame = audioBuffer.mData;
        [data appendBytes:frame length:audioBuffer.mDataByteSize];
    }
    
    CFRelease(sampleBuffer);
    
    [_self handleAudioBuffer:data];
}

- (void)handleElementaryStream:(NSData *)data
{
    NSData *nalUnits = [self avccFoNal:data];
    
    CMSampleBufferRef sampleBuffer = vt_sample_buffer_create(_formatDescription, (void *)[nalUnits bytes], (int)[nalUnits length]);
    
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    
    if (_delegate) {
        [_delegate didCompressFrameToH264SampleBuffer:data sampleBuffer:sampleBuffer];
    }
}

- (void)handleAudioBuffer:(NSData *)data {
    NSLog(@"%@", [data description]);
}

static CMSampleBufferRef vt_sample_buffer_create(CMFormatDescriptionRef fmt_desc, void *buffer, int size)
{
    OSStatus status;
    CMBlockBufferRef  block_buf;
    CMSampleBufferRef sample_buf;
    
    block_buf  = NULL;
    sample_buf = NULL;
    
    status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,///< structureAllocator
                                                buffer,             ///< memoryBlock
                                                size,               ///< blockLength
                                                kCFAllocatorNull,   ///< blockAllocator
                                                NULL,               ///< customBlockSource
                                                0,                  ///< offsetToData
                                                size,               ///< dataLength
                                                0,                  ///< flags
                                                &block_buf);
    
    if (!status) {
        status = CMSampleBufferCreate(kCFAllocatorDefault,  ///< allocator
                                      block_buf,            ///< dataBuffer
                                      TRUE,                 ///< dataReady
                                      0,                    ///< makeDataReadyCallback
                                      0,                    ///< makeDataReadyRefcon
                                      fmt_desc,             ///< formatDescription
                                      1,                    ///< numSamples
                                      0,                    ///< numSampleTimingEntries
                                      NULL,                 ///< sampleTimingArray
                                      0,                    ///< numSampleSizeEntries
                                      NULL,                 ///< sampleSizeArray
                                      &sample_buf);
    }
    
    if (block_buf) {
        CFRelease(block_buf);
    }
    
    return sample_buf;
}

void convertNALToAVCC(uint8_t *haystack, size_t index, int currentLength)
{
    int nalu_type = nalType(haystack, (int)index);
    NSLog(@"NALU with Type \"%@\" received. code (%i)", naluTypesStrings[nalu_type], nalu_type);

    int length = currentLength - 4;
    haystack[index]     = length >> 24;
    haystack[index + 1] = length >> 16;
    haystack[index + 2] = length >> 8;
    haystack[index + 3] = length;
}

- (NSData *)avccFoNal:(NSData *)data
{
    static const uint8_t needle[] = {0x00, 0x00, 0x00, 0x01};
    static const uint8_t needleLength = 4;
    
    size_t haystackLength = [data length];
    uint8_t *haystack = (uint8_t *)malloc(haystackLength);
    [data getBytes:haystack length:haystackLength];
    uint8_t testBuffer[needleLength];
    
    bool foundNalUnit = false;
    NSMutableArray *indexes = [[NSMutableArray alloc] init];
    NSMutableArray *lengths = [[NSMutableArray alloc] init];
    int currentLength = 0;
    for (int i = 0; i < haystackLength; i++) {
        
        if (foundNalUnit) {
            currentLength++;
        }
    
        for (int j = 0; j < needleLength; j++) {
            testBuffer[j] = haystack[i + j];
        }
        if (!memcmp(testBuffer, needle, 4 * sizeof(uint8_t))) {
            
            if (foundNalUnit) {
                size_t index = [indexes[indexes.count - 1] unsignedIntegerValue];
                convertNALToAVCC(haystack, index, currentLength);
                [lengths addObject:@(currentLength)];
            }
            
            foundNalUnit = true;
            [indexes addObject:@(i)];
            currentLength = 0;
        }
        
        if (i + 1 == haystackLength) {
            currentLength++;
            if (foundNalUnit) {
                size_t index = [indexes[indexes.count - 1] unsignedIntegerValue];
                convertNALToAVCC(haystack, index, currentLength);
                [lengths addObject:@(currentLength)];
            }
        }
    }

    NSData *avvcData = [NSData dataWithBytes:haystack length:haystackLength];
    free(haystack);
    
    return avvcData;
}

int nalType(uint8_t *buffer, int index) {
    int startCodeIndex = 0;
    for (int i = index; i < index + 5; i++) {
        if (buffer[i] == 0x01) {
            startCodeIndex = i;
            break;
        }
    }
    return ((uint8_t)buffer[startCodeIndex + 1] & 0x1F);
}

- (void)stop {
    [self.session stopRunning];
    self.session = nil;
}

- (double)mach_time_seconds {
    uint64_t mach_now = mach_absolute_time();
    return (double)((mach_now * _mach_timebase.numer / _mach_timebase.denom))/NSEC_PER_SEC;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (self.videoOutput == captureOutput) {
        CVImageBufferRef videoFrame = CMSampleBufferGetImageBuffer(sampleBuffer);
        
        _frameTime = [self mach_time_seconds];
        
        if (_firstFrameTime == 0) {
            _firstFrameTime = _frameTime;
        }
        CFAbsoluteTime presentationTimeStampTime = _frameTime - _firstFrameTime;
        _frameCount++;
        _lastFrameTime = _frameTime;
        
        CMTime presentationTimeStamp = CMTimeMake(presentationTimeStampTime*1000000, 1000000);
        
        VTCompressionSessionEncodeFrame(_compressionSession, videoFrame, presentationTimeStamp, kCMTimeInvalid, NULL, (__bridge void *)(self), NULL);
    } else if (self.audioOutput == captureOutput) {
        ReceiveAudioBuffer((__bridge void *)(self), sampleBuffer);
    }
}

@end