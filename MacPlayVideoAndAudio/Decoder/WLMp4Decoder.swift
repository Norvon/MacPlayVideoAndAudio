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
        audioPlayer?.pause()
        videoOutput = nil
        assetReader = nil
        audioPlayer = nil
        
        setIntendedSpatialExperience()
        handleInit()
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
}

extension WLMp4Decoder { // 处理视频渲染
    private func handleInit() {
        Task { @MainActor in
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
            
            
            var decompressionProperties: [String: Any] = [:]
            decompressionProperties[kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String] = [0, 1]
            
            var outputSettings: [String: Any] = [:]
            if videoInfo.isSpatial { // 处理 MVHEVC
                outputSettings[AVVideoDecompressionPropertiesKey] = decompressionProperties
            }
            outputSettings[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
            outputSettings[kCVPixelBufferMetalCompatibilityKey as String] = true
            
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
            let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
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
        
        guard let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder() else {
            print("Could not create a blit command encoder")
            return
        }
        
        

        
        if test {
            testRender(textures: textures, blitCommandEncoder: blitCommandEncoder, commandBuffer: commandBuffer)
        } else {
            if textures.count > 0 {
                blitCommandEncoder.copy(from: textures[0], to: leftEyeTexture)
            }
            if textures.count > 1 {
                blitCommandEncoder.copy(from: textures[1], to: rightEyeTexture)
            }
            
            blitCommandEncoder.endEncoding()
            commandBuffer.commit()
        }
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
    func getTextures(cmSampleBuffer: CMSampleBuffer) -> [MTLTexture]? {
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
    
    private func handleTaggedBuffers(_ taggedBuffers: [CMTaggedBuffer]) -> [MTLTexture]? { // 处理 MVHEVC
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
    
    private func getTextureCV(cvPixelBuffer: CVPixelBuffer) -> MTLTexture? {
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
        
        
        return CVMetalTextureGetTexture(metalTexture)
    }
    
    private func getTexture(cmSampleBuffer: CMSampleBuffer) -> MTLTexture? {
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
        let result = CVMetalTextureGetTexture(metalTexture)
        return result
    }
    
    private func convert(cvPixelBuffer: CVPixelBuffer) ->  CVMetalTexture? {
        guard let textureCache = metalTextureCache else {
            return nil
        }
        
        let width = CVPixelBufferGetWidth(cvPixelBuffer)
        let height = CVPixelBufferGetHeight(cvPixelBuffer)
        
        // Specify pixel format based on your CVPixelBuffer
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        
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
            return nil
        }
        
        if texture == nil {
            return nil
        }
        
        return texture!
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
