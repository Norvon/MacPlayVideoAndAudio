//
//  Test.h
//  MacPlayVideoAndAudio
//
//  Created by welink on 2024/8/26.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface Test : NSObject

+ (void)test:(CVPixelBufferRef)buffer;
@end

NS_ASSUME_NONNULL_END
