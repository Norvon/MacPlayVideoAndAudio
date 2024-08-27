//
//  WLMp4Decoder.swift
//  ATestVideo
//
//  Created by welink on 2024/6/7.
//

import AVFoundation
import VideoToolbox
import SwiftUI
import CoreFoundation
import RealityKit


class WLMp4Decoder: NSObject {
    @objc var willStartCallback: ((_ width: Int, _ height: Int, _ fps: Int) -> Void)?
    @objc var playCompleteCallback: ((Bool) -> Void)?
    
    private var audioPlayer: AVPlayer?
    private let device = MTLCreateSystemDefaultDevice()
    private var url: URL?
    
    private var metalTextureCache: CVMetalTextureCache?
    private let videoProcessingQueue: DispatchQueue = DispatchQueue(label: "com.wl.audio.obs.\(UUID().uuidString)", qos: .userInitiated)
    
    private var videoInfo: VideoInfo = VideoInfo()
    private var videoOutput: AVAssetReaderOutput?
    private var assetReader: AVAssetReader?
    private var timeObserverToken: Any?
    
    private var leftEyeTexture: MTLTexture?
    private var rightEyeTexture: MTLTexture?
    
    let test = true
    var testLeftLayer: CAMetalLayer?
    var testRightLayer: CAMetalLayer?
    var yuvToSRGBTexturePipeline: (any MTLRenderPipelineState)?
    
    var metalSource: String {
        get {
            """
            #include <metal_stdlib>
            using namespace metal;
            struct VertexOutput {
                float4 position [[position]];
                float2 texcoord;
            };
            constexpr sampler s = sampler(filter::linear);
            vertex VertexOutput vertex_sampler(const uint vid [[vertex_id]]) {
                const VertexOutput vertexData[3] = {
                    {{-1.0,  1.0, 0.0, 1.0}, {0.0, 0.0}},
                    {{ 3.0,  1.0, 0.0, 1.0}, {2.0, 0.0}},
                    {{-1.0, -3.0, 0.0, 1.0}, {0.0, 2.0}}
                };
                return vertexData[vid];
            }
            fragment half4 post_model_fragment(VertexOutput in [[stage_in]], texture2d<half> y_data [[texture(0)]], texture2d<half> uv_data [[texture(1)]]) {
                const half3x3 yuv_rgb = {
                    half3(1.0h, 1.0h, 1.0h),
                    half3(0.0h, -0.16455312684366h, 1.8814h),
                    half3(1.4746h, -0.57135312684366h, 0.0h)
                };
                half4 y = y_data.sample(s, in.texcoord);
                half4 uv = uv_data.sample(s, in.texcoord) - 0.5h;
                half3 yuv(y.x, uv.xy);
                half3 rgb_bt2020 = yuv_rgb * yuv;
            
                return half4(pow(rgb_bt2020, 2.2), 1);
            }
            """
        }
    }
    
    
    override init() {
        super.init()
        let compileOptions = MTLCompileOptions()
        compileOptions.fastMathEnabled = true
        guard let metalLibrary = try? device?.makeLibrary(source: metalSource, options: compileOptions) else {
            print("metalLibrary")
            return
        }
        
        let vertexFunction = metalLibrary.makeFunction(name: "vertex_sampler")
        let fragmentFunction = metalLibrary.makeFunction(name: "post_model_fragment")
        
        
        let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pipelineStateDescriptor.vertexFunction = vertexFunction
        pipelineStateDescriptor.fragmentFunction = fragmentFunction
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = .bgr10_xr_srgb
        yuvToSRGBTexturePipeline = try? device?.makeRenderPipelineState(descriptor: pipelineStateDescriptor)
    }
    
    
    @objc func play(url: URL, leftEyeTexture: MTLTexture?, rightEyeTexture: MTLTexture?) {
        audioPlayer?.pause()
        videoOutput = nil
        assetReader = nil
        audioPlayer = nil
        
        self.url = url
        self.leftEyeTexture = leftEyeTexture
        self.rightEyeTexture = rightEyeTexture
        
        setIntendedSpatialExperience()
        handleInit()
    }
    
    @objc func pause() {
        audioPlayer?.pause()
    }
    
    @objc func resume() {
        if audioPlayer?.status == .readyToPlay {
            audioPlayer?.play()
        }
    }
    
    @objc func rePlay() {
        seek(time: .zero)
    }
    
    @objc func setIntendedSpatialExperience() {
        Task { @MainActor in
            //            for item in UIApplication.shared.connectedScenes {
            //                if item.session.role == .immersiveSpaceApplication {
            //                    let experience: AVAudioSessionSpatialExperience
            //                    experience = .headTracked(soundStageSize: .large, anchoringStrategy: .scene(identifier: item.session.persistentIdentifier))
            //                    do {
            //                        try AVAudioSession.sharedInstance().setIntendedSpatialExperience(experience)
            //                    } catch {
            //                        print("setIntendedSpatialExperience error")
            //                        return
            //                    }
            //                    print("setIntendedSpatialExperience success")
            //                    return
            //                }
            //            }
            print("setIntendedSpatialExperience error ")
            return
        }
    }
    
    @objc func seek(time: CMTime) {
        guard let audioPlayer = audioPlayer else { return }
        if let token = timeObserverToken {
            audioPlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }
        
        pause()
        audioPlayer.seek(to: time) {success in
            if success {
                Task { @MainActor in
                    let _ = await self.videoSeek(to: audioPlayer.currentTime())
                    self.resume()
                }
            }
        }
    }
}

extension WLMp4Decoder { // 处理视频渲染
    
    private func videoSeek(to time: CMTime) async -> Bool {
        assetReader?.cancelReading()
        
        guard let url = url else { return false}
        let asset = AVURLAsset(url: url)
        guard let newAssetReader = try? AVAssetReader(asset: asset) else { return false }
        self.assetReader = newAssetReader
        
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("Failed to get video info")
            return false
        }
        
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: getOutputSettings(videoInfo))
        if(newAssetReader.canAdd(videoOutput)){
            newAssetReader.add(videoOutput)
        }
        
        newAssetReader.timeRange = CMTimeRange(start: time, duration: .positiveInfinity)
        
        self.videoOutput = videoOutput
        
        
        if newAssetReader.startReading() {
            print("开始读取")
            assetReader = newAssetReader
        } else {
            print("无法启动阅读器: \(newAssetReader.error.debugDescription)")
            print("文件是否存在：\(FileManager.default.fileExists(atPath: url.path()))")
            newAssetReader.cancelReading()
        }
        
        setupTimeObserver()
        
        return true
    }
    
    private func getOutputSettings(_ videoInfo: VideoInfo) -> [String: Any] {
        var decompressionProperties: [String: Any] = [:]
        decompressionProperties[kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String] = [0, 1]
        
        var outputSettings: [String: Any] = [:]
        if videoInfo.isSpatial { // 处理 MVHEVC
            outputSettings[AVVideoDecompressionPropertiesKey] = decompressionProperties
        }
        outputSettings[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        outputSettings[kCVPixelBufferMetalCompatibilityKey as String] = true
        return outputSettings
    }
    
    private func handleInit() {
        Task { @MainActor in
            
            if let token = timeObserverToken {
                audioPlayer?.removeTimeObserver(token)
                timeObserverToken = nil
            }
            
            guard let url = url else { return }
            let asset = AVURLAsset(url: url)
            guard let assetReader = try? AVAssetReader(asset: asset) else {
                print("Failed assetReader")
                return
            }
            self.assetReader = assetReader
            
            guard let videoInfo = await VideoTools.getVideoInfo(asset: asset) else {
                print("Failed to get video info")
                return
            }
            
            
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                print("Failed to get video info")
                return
            }
            
            if let fps = try? await track.load(.nominalFrameRate) {
                videoInfo.fps = Int(fps)
            }
            
            self.willStartCallback?(Int(videoInfo.size.width), Int(videoInfo.size.height), videoInfo.fps)
            
            if videoInfo.fps <= 0 {
                videoInfo.fps = 30
            }
            print("fps:\(videoInfo.fps) ")
            self.videoInfo = videoInfo
            let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: getOutputSettings(videoInfo))
            if(assetReader.canAdd(videoOutput)){
                assetReader.add(videoOutput)
            }
            self.videoOutput = videoOutput
            
            guard let assetAudioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
                print("Failed to get audioTrack")
                return
            }
            
            //            let audioItem = AVPlayerItem(asset: asset)
            //            audioPlayer = AVPlayer(playerItem: audioItem)
            
            
            guard let duration = try? await asset.load(.duration) else {
                return
            }
            
            
            let composition = AVMutableComposition()
            if let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                                   of: assetAudioTrack,
                                                   at: .zero)
                } catch {
                    print("Error copying audio track: \(error)")
                }
            }
            
            let playerItem = AVPlayerItem(asset: composition)
            audioPlayer = AVPlayer(playerItem: playerItem)
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerDidFinishPlaying),
                name: .AVPlayerItemDidPlayToEndTime,
                object: playerItem
            )
            
            audioPlayer?.play()
            if assetReader.startReading() {
                print("开始读取")
            } else {
                print("无法启动阅读器: \(assetReader.error.debugDescription)")
                print("文件是否存在：\(FileManager.default.fileExists(atPath: url.path()))")
                assetReader.cancelReading()
            }
            
            setupTimeObserver()
        }
    }
    
    
    @objc func playerDidFinishPlaying(note: NSNotification) {
        print("播放完成")
        playCompleteCallback?(true)
    }
    
    private func setupTimeObserver() {
        guard let audioPlayer = audioPlayer else { return }
        let interval = CMTime(seconds: 1.0 / Double(videoInfo.fps), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = audioPlayer.addPeriodicTimeObserver(forInterval: interval, queue: videoProcessingQueue) { [weak self] time in
            self?.updateVideoFrame(at: time)
        }
    }
    
    private func updateVideoFrame(at time: CMTime) {
        
        guard let audioPlayer = audioPlayer else { return }
        
        //        guard let leftEyeTexture = leftEyeTexture,
        //              let rightEyeTexture = rightEyeTexture else {
        //            return
        //        }
        
        guard let assetReader = self.assetReader else {
            print("Failed not found assetReader ")
            return
        }
        
        if assetReader.status == .completed {
            print("assetReader completed")
            playCompleteCallback?(true)
            return
        }
        
        if assetReader.status != .reading {
            print("assetReader status = \(assetReader.status)")
            return
        }
        
        
        guard let nextSampleBuffer = self.videoOutput?.copyNextSampleBuffer() else {
            return
        }
        
        let tempAudioTime = audioPlayer.currentTime()
        let audioTime = tempAudioTime
        
        let tempVideoTime = CMSampleBufferGetPresentationTimeStamp(nextSampleBuffer)
        let videoTime = tempVideoTime
        
        let videoCurrent = CMTimeGetSeconds(videoTime)
        let audioCurrent = CMTimeGetSeconds(audioTime)
        
        let offset = videoCurrent - audioCurrent
        print("offset = \(offset)")
        if offset < -0.1 {
            while let nextBuffer = videoOutput?.copyNextSampleBuffer() {
                let nextFrameTime = CMSampleBufferGetPresentationTimeStamp(nextBuffer)
                if CMTimeCompare(nextFrameTime, tempAudioTime) >= 0 {
                    break
                }
            }
        } else if offset > 0.1 {
            return
        }
        
        guard let textures = getTextures(cmSampleBuffer: nextSampleBuffer) else {
            print("textures not found")
            return
        }
        
        guard let leftEyeTexture = leftEyeTexture,
              let rightEyeTexture = rightEyeTexture else {
            return
        }
        
        guard let commandQueue = device?.makeCommandQueue() else {
            print("commandQueue not found")
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("commandBuffer not found")
            return
        }
        
        let renderPassDescriptorLeft = MTLRenderPassDescriptor()
        renderPassDescriptorLeft.colorAttachments[0].texture = testLeftLayer!.nextDrawable()!.texture
        renderPassDescriptorLeft.colorAttachments[0].loadAction = .clear
        renderPassDescriptorLeft.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderPassDescriptorLeft.colorAttachments[0].storeAction = .store
        
        let renderEncoderLeft = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptorLeft)
        renderEncoderLeft?.setRenderPipelineState(yuvToSRGBTexturePipeline!)
        renderEncoderLeft?.setFragmentTexture(textures[0].yMTLTexture, index: 0)
        renderEncoderLeft?.setFragmentTexture(textures[0].uvMTLvTexture, index: 1)
        
        // 设置顶点缓冲区、绘制
        renderEncoderLeft?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoderLeft?.endEncoding()
        
        
        
        let renderPassDescriptorRight = MTLRenderPassDescriptor()
        renderPassDescriptorRight.colorAttachments[0].texture = testRightLayer!.nextDrawable()!.texture
        renderPassDescriptorRight.colorAttachments[0].loadAction = .clear
        renderPassDescriptorRight.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderPassDescriptorRight.colorAttachments[0].storeAction = .store
        
        let renderEncoderRight = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptorRight)
        renderEncoderRight?.setRenderPipelineState(yuvToSRGBTexturePipeline!)
        renderEncoderRight?.setFragmentTexture(textures[1].yMTLTexture, index: 0)
        renderEncoderRight?.setFragmentTexture(textures[1].uvMTLvTexture, index: 1)
        
        // 设置顶点缓冲区、绘制
        renderEncoderRight?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoderRight?.endEncoding()
        
        
        commandBuffer.commit()
        testLeftLayer?.nextDrawable()?.present()
        testRightLayer?.nextDrawable()?.present()
        
        commandBuffer.waitUntilCompleted()
        
        //        guard let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder() else {
        //            print("Could not create a blit command encoder")
        //            return
        //        }
        
        //        if test {
        //            testRender(textures: textures, blitCommandEncoder: blitCommandEncoder, commandBuffer: commandBuffer)
        //        } else {
        //            if textures.count > 0 {
        //                blitCommandEncoder.copy(from: textures[0], to: leftEyeTexture)
        //            }
        //            if textures.count > 1 {
        //                blitCommandEncoder.copy(from: textures[1], to: rightEyeTexture)
        //            }
        //
        //            blitCommandEncoder.endEncoding()
        //            commandBuffer.commit()
        //        }
    }
    
    private func testRender(textures: [any MTLTexture],
                            blitCommandEncoder: any MTLBlitCommandEncoder,
                            commandBuffer: any MTLCommandBuffer) {
        
        //        let centerX = (textures[0].width - 100) / 2
        //        let centerY = (textures[0].height - 100) / 2
        
        if let left = testLeftLayer?.nextDrawable() {
            let region = MTLRegionMake2D(0, 0, left.texture.width, left.texture.height)
            
            //            blitCommandEncoder.copy(from: textures.first!, to: left.texture)
            blitCommandEncoder.copy(from: textures[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: left.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            
        }
        
        if let right = testRightLayer?.nextDrawable() {
            let region = MTLRegionMake2D(textures[0].width - right.texture.width, 0, right.texture.width, right.texture.height)
            if textures.count > 1 {
                //                blitCommandEncoder.copy(from: textures[1], to: right.texture)
                blitCommandEncoder.copy(from: textures[1], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: right.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            } else if textures.count == 1 {
                //                blitCommandEncoder.copy(from: textures.first!, to: right.texture)
                blitCommandEncoder.copy(from: textures[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: right.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            }
        }
        
        blitCommandEncoder.endEncoding()
        
        testLeftLayer?.nextDrawable()?.present()
        testRightLayer?.nextDrawable()?.present()
        
        commandBuffer.commit()
    }
}

extension WLMp4Decoder { // 处理 texture
    func getTextures(cmSampleBuffer: CMSampleBuffer) -> [WLMTLTexture]? {
        if let taggedBuffers = cmSampleBuffer.taggedBuffers {
            let result = handleTaggedBuffers(taggedBuffers)
            return result
        } else {
            guard let texture = getTexture(cmSampleBuffer:cmSampleBuffer) else  {
                
                return nil
            }
            
            return [texture]
        }
    }
    
    private func handleTaggedBuffers(_ taggedBuffers: [CMTaggedBuffer]) -> [WLMTLTexture]? { // 处理 MVHEVC
        let leftEyeBuffer = taggedBuffers.first(where: {
            $0.tags.first(matchingCategory: .stereoView) == .stereoView(.leftEye)
        })?.buffer
        let rightEyeBuffer = taggedBuffers.first(where: {
            $0.tags.first(matchingCategory: .stereoView) == .stereoView(.rightEye)
        })?.buffer
        
        if let leftEyeBuffer,
           let rightEyeBuffer,
           case let .pixelBuffer(leftEyePixelBuffer) = leftEyeBuffer,
           case let .pixelBuffer(rightEyePixelBuffer) = rightEyeBuffer {
            
            guard let leftTexture = getTextureCV(cvPixelBuffer: leftEyePixelBuffer),
                  let rightTexture = getTextureCV(cvPixelBuffer: rightEyePixelBuffer) else {
                return nil
            }
            
            return [leftTexture, rightTexture]
        }
        
        return nil
    }
    
    private func getTextureCV(cvPixelBuffer: CVPixelBuffer) -> WLMTLTexture? {
        guard let device = device else {
            print("device 获取失败")
            return nil
        }
        
        if metalTextureCache == nil {
            guard let metalTextureCache = createMetalTextureCache(device: device) else {
                print("无法创建Metal纹理缓存")
                return nil
            }
            self.metalTextureCache = metalTextureCache
        }
        guard let metalTexture = convert(cvPixelBuffer: cvPixelBuffer) else {
            print("无法创建metalTexture纹理缓存")
            return nil
        }
        
        
        var wlMTLTexture = WLMTLTexture()
        if let tmp = metalTexture.yCVMetalTexture {
            wlMTLTexture.yMTLTexture = CVMetalTextureGetTexture(tmp)
        }
        
        if let tmp = metalTexture.uvCVMetalTexture {
            wlMTLTexture.uvMTLvTexture = CVMetalTextureGetTexture(tmp)
        }
        return wlMTLTexture
    }
    
    private func getTexture(cmSampleBuffer: CMSampleBuffer) -> WLMTLTexture? {
        guard let device = device else {
            print("device 获取失败")
            return nil
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(cmSampleBuffer) else {
            print("pixelBuffer 获取失败")
            return nil
        }
        
        if metalTextureCache == nil {
            guard let metalTextureCache = createMetalTextureCache(device: device) else {
                print("无法创建Metal纹理缓存")
                return nil
            }
            self.metalTextureCache = metalTextureCache
        }
        guard let metalTexture = convert(cvPixelBuffer: pixelBuffer) else {
            print("无法创建metalTexture纹理缓存")
            return nil
        }
        
        var wlMTLTexture = WLMTLTexture()
        if let tmp = metalTexture.yCVMetalTexture {
            wlMTLTexture.yMTLTexture = CVMetalTextureGetTexture(tmp)
        }
        
        if let tmp = metalTexture.uvCVMetalTexture {
            wlMTLTexture.uvMTLvTexture = CVMetalTextureGetTexture(tmp)
        }
        return wlMTLTexture
    }
    
    
    private func convert(cvPixelBuffer: CVPixelBuffer) -> WLCVMetalTexture? {
        guard let textureCache = metalTextureCache else {
            return nil
        }
        
        Test.test(cvPixelBuffer)
        
        var wlCVMetalTexture = WLCVMetalTexture()
        let width = CVPixelBufferGetWidth(cvPixelBuffer)
        let height = CVPixelBufferGetHeight(cvPixelBuffer)
        
        // Specify pixel format based on your CVPixelBuffer
        let pixelFormat = MTLPixelFormat.r16Unorm
        
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               cvPixelBuffer,
                                                               nil,
                                                               pixelFormat,
                                                               width,
                                                               height,
                                                               0,
                                                               &texture)
        if status != kCVReturnSuccess {
            wlCVMetalTexture.yCVMetalTexture = nil
        } else {
            wlCVMetalTexture.yCVMetalTexture = texture
        }
        
        
        var secondTexture: CVMetalTexture?
        let secondStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                     textureCache,
                                                                     cvPixelBuffer,
                                                                     nil,
                                                                     .rg16Unorm,
                                                                     width / 2,
                                                                     height / 2,
                                                                     1,
                                                                     &secondTexture)
        if secondStatus != kCVReturnSuccess {
            wlCVMetalTexture.uvCVMetalTexture = nil
        } else {
            wlCVMetalTexture.uvCVMetalTexture = secondTexture
        }
        
        return wlCVMetalTexture
    }
    
    private func createMetalTextureCache(device: MTLDevice) -> CVMetalTextureCache? {
        var textureCache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        
        if result != kCVReturnSuccess {
            return nil
        }
        
        return textureCache
    }
}

struct WLCVMetalTexture {
    var yCVMetalTexture: CVMetalTexture?
    var uvCVMetalTexture: CVMetalTexture?
}

struct WLMTLTexture {
    var yMTLTexture: MTLTexture?
    var uvMTLvTexture: MTLTexture?
}
