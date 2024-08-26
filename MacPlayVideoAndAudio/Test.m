//
//  Test.m
//  MacPlayVideoAndAudio
//
//  Created by welink on 2024/8/26.
//

#import "Test.h"
#import <CoreVideo/CoreVideo.h>

@implementation Test
+ (void)test:(CVPixelBufferRef)buffer {
    NSLog(@"buffer = %@ ", buffer);
}
@end
