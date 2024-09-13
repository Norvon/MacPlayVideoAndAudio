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

class WLMp4Decoder: NSObject {
    @objc var willStartCallback: ((_ width: Int, _ height: Int, _ fps: Int, _ format: Int) -> Void)?
    @objc var playCompleteCallback: (() -> Void)?
    @objc var idx: Int = 0
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
    
    var test = false
    var testLeftLayer: CAMetalLayer?
    var testRightLayer: CAMetalLayer?
    
    private var _identifier:UInt64 = 0;
    @objc var volume: Float { // 音量范围（0 - 1）
        set {
            audioPlayer?.volume = newValue
        }
        get {
            return audioPlayer?.volume ?? 0
        }
    }
    
    @objc var currentTime :Double {
        get {
            return audioPlayer?.currentTime().seconds ?? 0.0
        }
    }
    @objc func setTexture(leftEyeTexture: MTLTexture?, rightEyeTexture: MTLTexture?) {
        self.leftEyeTexture = leftEyeTexture
        self.rightEyeTexture = rightEyeTexture
    }
    
    private func getOutputSettings(_ videoInfo: VideoInfo) -> [String: Any] {
        var decompressionProperties: [String: Any] = [:]
        decompressionProperties[kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String] = [0, 1]
        
        var outputSettings: [String: Any] = [:]
        if videoInfo.isSpatial { // 处理 MVHEVC
            outputSettings[AVVideoDecompressionPropertiesKey] = decompressionProperties
        }
#if targetEnvironment(simulator)
        //        outputSettings[AVVideoColorPropertiesKey] = [
        //            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        //            AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
        //            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        //        ]
#else
        // 判断 Color Primaries
        switch videoInfo.colorPrimaries {
        case AVVideoColorPrimaries_ITU_R_2020:
            outputSettings[AVVideoColorPropertiesKey] = [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
                
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        default:
            outputSettings[AVVideoColorPropertiesKey] = [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
                
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
            break
        }
#endif
#if LGTEST
        outputSettings[kCVPixelBufferPixelFormatTypeKey as String] = Int(kCVPixelFormatType_32BGRA)
#else
        outputSettings[kCVPixelBufferPixelFormatTypeKey as String] = Int(kCVPixelFormatType_64RGBAHalf)
#endif
        outputSettings[kCVPixelBufferMetalCompatibilityKey as String] = true
        
        return outputSettings
    }
    
    
    @objc func seek(time: CMTime) {
        if let token = timeObserverToken {
            audioPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        pause()
        audioPlayer?.seek(to: time) {success in
            if success {
                Task {
                    let _ = await self.videoSeek(to: time)
                }
            }
        }
    }
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
    
    
    @objc func initPlayer(url: URL,identifier:UInt64) {
        _identifier = identifier
        audioPlayer?.pause()
        videoOutput = nil
        assetReader = nil
        audioPlayer = nil
        
        self.url = url
        setIntendedSpatialExperience()
        handleInit()
    }
    @objc func play(){
        audioPlayer?.play()
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
    
    private func clearCache() {
        self.metalTextureCache = nil
    }
    
    @objc func setIntendedSpatialExperience() {
#if LGTEST
        print("")
#else
        Task { @MainActor in
            let experience: AVAudioSessionSpatialExperience
            do {
                experience = .headTracked(soundStageSize: .large, anchoringStrategy: .scene(identifier: "\(AlphaViewManager.shared.entities[self.idx].id)"))
                try AVAudioSession.sharedInstance().setIntendedSpatialExperience(experience)
                try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback, mode: AVAudioSession.Mode.moviePlayback, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
                
                print("setIntendedSpatialExperience success")
                return
            } catch {
                print("setIntendedSpatialExperience error")
                return
            }
        }
#endif
    }
}

extension WLMp4Decoder { // 处理视频渲染
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
                videoInfo.fps = fps
            }
            
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
            
            let composition = AVMutableComposition()
            if let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                                   of: assetAudioTrack,
                                                   at: .zero)
                } catch {
                    print("Error copying audio track: \(error)")
                }
            }
            
            let audioItem = AVPlayerItem(asset: composition)
            audioPlayer = AVPlayer(playerItem: audioItem)
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerDidFinishPlaying),
                name: .AVPlayerItemDidPlayToEndTime,
                object: audioItem
            )
            
#if LGTEST
#else
            if let audioPlayer = audioPlayer {
                var videoPlayerComponent = VideoPlayerComponent(avPlayer: audioPlayer)
                videoPlayerComponent.desiredViewingMode = VideoPlaybackController.ViewingMode.stereo
                videoPlayerComponent.isPassthroughTintingEnabled = false
                
                AlphaViewManager.shared.entities[idx].components.set(videoPlayerComponent)
            }
#endif
            
            if assetReader.startReading() {
                print("开始读取")
            } else {
                print("无法启动阅读器: \(assetReader.error.debugDescription)")
                print("文件是否存在：\(FileManager.default.fileExists(atPath: url.path()))")
                assetReader.cancelReading()
            }
            
            setupTimeObserver()
            self.willStartCallback?(Int(videoInfo.size.width), Int(videoInfo.size.height), Int(videoInfo.fps),Int(9))
        }
    }
    @objc func playerDidFinishPlaying() {
        print("播放完成")
        pause()
        clearCache()
        playCompleteCallback?()
    }
    
    private func setupTimeObserver() {
        guard let audioPlayer = audioPlayer else { return }
        let interval = CMTime(seconds: 1.0 / Double(videoInfo.fps), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = nil
        timeObserverToken = audioPlayer.addPeriodicTimeObserver(forInterval: interval, queue: videoProcessingQueue) { [weak self] time in
            
            self?.updateVideoFrame(at: time)
        }
    }
    
    private func updateVideoFrame(at time: CMTime) {
        guard let leftEyeTexture = leftEyeTexture,
              let rightEyeTexture = rightEyeTexture else {
            return
        }
        
        guard let assetReader = self.assetReader else {
            print("Failed not found assetReader ")
            return
        }
        
        if assetReader.status == .completed {
            print("assetReader completed")
            //            playCompleteCallback?()
            playerDidFinishPlaying()
            return
        }
        
        if assetReader.status != .reading {
            print("assetReader status = \(assetReader.status)")
            return
        }
        
        
        guard let nextSampleBuffer = self.videoOutput?.copyNextSampleBuffer() else {
            return
        }
        
        let tempAudioTime = audioPlayer!.currentTime()
        let audioTime = tempAudioTime
        
        let tempVideoTime = CMSampleBufferGetPresentationTimeStamp(nextSampleBuffer)
        let videoTime = tempVideoTime
        
        let videoCurrent = CMTimeGetSeconds(videoTime)
        let audioCurrent = CMTimeGetSeconds(audioTime)
        
        let offset = videoCurrent - audioCurrent
        //        print("idx:\(self.idx)--offset = \(offset)")
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
            if textures.count >= 1 {
                if (textures[0].width == leftEyeTexture.width && textures[0].height == leftEyeTexture.height){
                    blitCommandEncoder.copy(from: textures[0], to: leftEyeTexture)
                }
                else{
                    print("idx = \(idx)左眼RT(\(textures[0].width)-\(textures[0].height))----(\(leftEyeTexture.width)-\(leftEyeTexture.height))")
                }
                
            }
            if textures.count > 1 {
                if (textures[1].width == rightEyeTexture.width && textures[1].height == rightEyeTexture.height){
                    blitCommandEncoder.copy(from: textures[1], to: rightEyeTexture)
                }
                else{
                    print("左眼RT(\(textures[1].width)-\(textures[1].height))----(\(rightEyeTexture.width)-\(rightEyeTexture.height))")
                }
                
            }
            blitCommandEncoder.endEncoding()
            commandBuffer.commit()
        }
    }
    
    private func testRender(textures: [any MTLTexture],
                            blitCommandEncoder: any MTLBlitCommandEncoder,
                            commandBuffer: any MTLCommandBuffer) {
        
        let renderW = Int(testRightLayer!.drawableSize.width)
        let renderH = Int(testRightLayer!.drawableSize.height)
        
        let bufferW = textures.first!.width
        let bufferH = textures.first!.height
        
        
        let region = MTLRegionMake2D((bufferW - renderW) / 2, (bufferH - renderH) / 2, renderW, renderH)
        
        if let left = testLeftLayer?.nextDrawable() {
            blitCommandEncoder.copy(from: textures[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: left.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
        }
        
        if let right = testRightLayer?.nextDrawable() {
            if textures.count > 1 {
                blitCommandEncoder.copy(from: textures[1], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: right.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            } else if textures.count == 1 {
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
#if LGTEST
        let pixelFormat = MTLPixelFormat.bgra8Unorm
#else
        let pixelFormat = MTLPixelFormat.rg11b10Float
#endif
        
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
