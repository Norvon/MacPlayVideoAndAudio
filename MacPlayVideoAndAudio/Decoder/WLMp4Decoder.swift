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
    @objc var willStartCallback: ((_ width: Int, _ height: Int, _ fps: Int, _ secondWidth: Int, _ secondHeight: Int, _ secondFps: Int, _ format: Int) -> Void)?
    @objc var playCompleteCallback: (() -> Void)?
    @objc var idx: Int = 0
    private var audioPlayer: AVPlayer?
    private var audioPaused: Bool = false
    private let device = MTLCreateSystemDefaultDevice()
    private var url: URL?
    private var secondUrl: URL?
    private var secondStart: CMTime = .zero
    private var secondSeek: CMTime = .zero
    
    private var metalTextureCache: CVMetalTextureCache?
    private let videoProcessingQueue: DispatchQueue = DispatchQueue(label: "com.wl.audio.obs.\(UUID().uuidString)", qos: .userInteractive)
    private let renderQueue: DispatchQueue = DispatchQueue(label: "com.wl.render.\(UUID().uuidString)", qos: .userInteractive)
    
    private var videoInfo: VideoInfo = VideoInfo()
    private var secondVideoInfo: VideoInfo = VideoInfo()
    private var firstAssetReader: AVAssetReader?
    private var secondAssetReader: AVAssetReader?
    private var timeObserverToken: Any?
    
    private var leftEyeTexture: MTLTexture?
    private var rightEyeTexture: MTLTexture?
    private var secondLeftEyeTexture: MTLTexture?
    private var secondRightEyeTexture: MTLTexture?
    
    var test = false
    var testLeftLayer: CAMetalLayer?
    var testRightLayer: CAMetalLayer?
    var testSecondLeftLayer: CAMetalLayer?
    var testSecondRightLayer: CAMetalLayer?
    
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
    @objc func setTexture(leftEyeTexture: MTLTexture?, rightEyeTexture: MTLTexture?, secondLeftEyeTexture: MTLTexture?, secondRightEyeTexture: MTLTexture?) {
        self.leftEyeTexture = leftEyeTexture
        self.rightEyeTexture = rightEyeTexture
        self.secondLeftEyeTexture = leftEyeTexture
        self.secondRightEyeTexture = rightEyeTexture
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
        audioPlayer?.seek(to: time) {[weak self] success in
            guard let self = self else { return }
            if success {
                Task {
                    let offset = time.seconds - (self.secondStart.seconds + self.secondSeek.seconds)
                    let seekTime = CMTime(seconds: (offset > 0 ? offset : 0) + self.secondSeek.seconds, preferredTimescale: 1)
                    self.secondAssetReader = await self.videoSeek(seekTime, self.secondUrl, self.secondAssetReader, self.secondVideoInfo)
                    self.secondAssetReader?.outputs.first?.copyNextSampleBuffer()
                    
                    if let reader = await self.videoSeek(time, self.url, self.firstAssetReader, self.videoInfo) {
                        self.firstAssetReader = reader
                        self.setupTimeObserver()
                    }
                }
            }
        }
    }
    private func videoSeek(_ time: CMTime , _ url: URL?, _ assetReader: AVAssetReader?, _ videoInfo: VideoInfo) async -> AVAssetReader? {
        assetReader?.cancelReading()
        guard let url = url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let newAssetReader = try? AVAssetReader(asset: asset) else { return nil }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("Failed to get video info")
            return nil
        }
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: getOutputSettings(videoInfo))
        if(newAssetReader.canAdd(videoOutput)){
            newAssetReader.add(videoOutput)
        } else {
            return nil
        }
        newAssetReader.timeRange = CMTimeRange(start: time, duration: .positiveInfinity)
        if newAssetReader.startReading() {
            print("开始读取")
            return newAssetReader
        } else {
            print("无法启动阅读器: \(newAssetReader.error.debugDescription)")
            print("文件是否存在：\(FileManager.default.fileExists(atPath: url.path()))")
            newAssetReader.cancelReading()
        }
        
        return nil
    }
    
    
    @objc func initPlayer(url: URL, secondUrl: URL?, secondStart: CMTime, secondSeek: CMTime) {
        audioPlayer?.pause()
        firstAssetReader = nil
        secondAssetReader = nil
        audioPlayer = nil
        
        self.url = url
        self.secondUrl = secondUrl
        self.secondStart = secondStart
        self.secondSeek = secondSeek
        setIntendedSpatialExperience()
        handleInit()
    }
    
    @objc func play(){
        audioPaused = false
        audioPlayer?.play()
    }
    
    @objc func pause() {
        audioPaused = true
        audioPlayer?.pause()
    }
    
    @objc func resume() {
        if audioPlayer?.status == .readyToPlay {
            audioPaused = false
            audioPlayer?.play()
        }
    }
    
    @objc func rePlay() {
        seek(time: .zero)
        audioPaused = false
        audioPlayer?.play()
    }
    
    private func clearCache() {
        self.metalTextureCache = nil
    }
    
    @objc func setIntendedSpatialExperience() {
#if LGTEST
        
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
    
    func getReaderAndVideoInfo(_ asset: AVURLAsset) async -> (AVAssetReader, VideoInfo)? {
        guard let assetReader = try? AVAssetReader(asset: asset) else {
            print("Failed assetReader")
            return nil
        }
        
        
        guard let videoInfo = await VideoTools.getVideoInfo(asset: asset) else {
            print("Failed to get video info")
            return nil
        }
        
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("Failed to get video info")
            return nil
        }
        
        if let fps = try? await track.load(.nominalFrameRate) {
            videoInfo.fps = fps
        }
        
        if videoInfo.fps <= 0 {
            videoInfo.fps = 30
        }
        
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: getOutputSettings(videoInfo))
        if(assetReader.canAdd(videoOutput)){
            assetReader.add(videoOutput)
        } else {
            return nil
        }
        
        return (assetReader, videoInfo)
    }
    
    private func handleInit() {
        Task { @MainActor in
            if let token = timeObserverToken {
                audioPlayer?.removeTimeObserver(token)
                timeObserverToken = nil
            }
            
            guard let url = url else { return }
            let asset = AVURLAsset(url: url)
            if await handleVideo(asset) == false {
                return
            }
            
            await handleSecondVideo(secondSeek)
            
            if await handleAudio(asset) == false {
                return
            }
            
            guard let assetReader = firstAssetReader else {
                return
            }
            
            if assetReader.status == .reading {
                assetReader.cancelReading()
            }
            
            if assetReader.startReading() {
                print("开始读取")
            } else {
                print("无法启动阅读器: \(assetReader.error.debugDescription)")
                print("文件是否存在：\(FileManager.default.fileExists(atPath: url.path()))")
                assetReader.cancelReading()
            }
            assetReader.outputs.first?.copyNextSampleBuffer()
            setupTimeObserver()
            self.willStartCallback?(Int(videoInfo.size.width), 
                                    Int(videoInfo.size.height),
                                    Int(videoInfo.fps),
                                    Int(secondVideoInfo.size.width),
                                    Int(secondVideoInfo.size.height),
                                    Int(secondVideoInfo.fps),
                                    Int(9))
        }
    }
    
    private func handleAudio(_ asset: AVURLAsset) async -> Bool {
        guard let assetAudioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            print("Failed to get audioTrack")
            return false
        }
        
        let composition = AVMutableComposition()
        if let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            do {
                try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                               of: assetAudioTrack,
                                               at: .zero)
            } catch {
                print("Error copying audio track: \(error)")
                return false
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
        
        return true
    }
    
    private func handleVideo(_ asset: AVURLAsset) async -> Bool{
        guard let readerAndVideoInfo = await getReaderAndVideoInfo(asset) else {
            return false
        }
        
        let assetReader = readerAndVideoInfo.0
        let videoInfo = readerAndVideoInfo.1
        self.firstAssetReader = assetReader
        self.videoInfo = videoInfo
        return true
    }
    
    private func handleSecondVideo(_ seekTime: CMTime = .zero) async {
        guard let url = secondUrl else { return }
        let asset = AVURLAsset(url: url)
        guard let readerAndVideoInfo = await getReaderAndVideoInfo(asset) else {
            self.secondAssetReader = nil
            return
        }
        
        let assetReader = readerAndVideoInfo.0
        self.secondAssetReader = assetReader
        self.secondVideoInfo = readerAndVideoInfo.1
        
        assetReader.timeRange = CMTimeRange(start: seekTime, duration: .positiveInfinity)
        
        if assetReader.startReading() {
            print("开始读取")
        } else {
            print("无法启动阅读器: \(assetReader.error.debugDescription)")
            print("文件是否存在：\(FileManager.default.fileExists(atPath: url.path()))")
            assetReader.cancelReading()
        }
        assetReader.outputs.first?.copyNextSampleBuffer()
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
            self?.preRender(time)
        }
    }
    
    private func preRender(_ time: CMTime) {
        if audioPaused {
            return
        }
        
        var secondSampleBuffer: CMSampleBuffer? = nil
        guard let firstSampleBuffer = self.getNextSampleBuffer(time, self.firstAssetReader) else {
            return
        }
        
        let offset = time.seconds - secondStart.seconds
        if offset >= 0 {
            //            print("time.seconds = \(time.seconds)")
            let adjustedTime = CMTime(seconds: self.secondSeek.seconds + offset, preferredTimescale: time.timescale)
            secondSampleBuffer = self.getNextSampleBuffer(adjustedTime, self.secondAssetReader, false)
        }
        if secondSampleBuffer != nil  {
            let first = CMSampleBufferGetPresentationTimeStamp(firstSampleBuffer)
            let second = CMSampleBufferGetPresentationTimeStamp(secondSampleBuffer!)
            print("second offset = \(first.seconds - second.seconds)")
        }
        
        renderQueue.sync {
            render(firstSampleBuffer, secondSampleBuffer)
        }
    }
    
    private func render(_ buffer: CMSampleBuffer, _ secondBuffer: CMSampleBuffer?) {
        guard let leftEyeTexture = leftEyeTexture,
              let rightEyeTexture = rightEyeTexture else {
            return
        }
        
        guard let textures = getTextures(cmSampleBuffer: buffer) else {
            print("textures not found")
            return
        }
        
        let secoundTextures = getTextures(cmSampleBuffer: secondBuffer)
        
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
        
        if test == false {
            wlCopyTeture(blitCommandEncoder: blitCommandEncoder, textures: textures, leftEyeTexture: leftEyeTexture, rightEyeTexture: rightEyeTexture)
            
            if let secoundTextures = secoundTextures,
               let secondLeftEyeTexture = secondLeftEyeTexture,
               let secondRightEyeTexture = secondRightEyeTexture {
                wlCopyTeture(blitCommandEncoder: blitCommandEncoder, textures: secoundTextures, leftEyeTexture: secondLeftEyeTexture, rightEyeTexture: secondRightEyeTexture)
            }
            
            blitCommandEncoder.endEncoding()
            commandBuffer.commit()
        } else {
            testRender(textures: textures, secondTextures: secoundTextures,  blitCommandEncoder: blitCommandEncoder, commandBuffer: commandBuffer)
        }
    }
    
    func wlCopyTeture(blitCommandEncoder: any MTLBlitCommandEncoder,
                      textures: [any MTLTexture],
                      leftEyeTexture: any MTLTexture,
                      rightEyeTexture: any MTLTexture) {
        if textures.count >= 1 {
            if (textures[0].width == leftEyeTexture.width && textures[0].height == leftEyeTexture.height){
                blitCommandEncoder.copy(from: textures[0], to: leftEyeTexture)
            } else {
                print("idx = \(idx)左眼RT(\(textures[0].width)-\(textures[0].height))----(\(leftEyeTexture.width)-\(leftEyeTexture.height))")
            }
        }
        if textures.count > 1 {
            if (textures[1].width == rightEyeTexture.width && textures[1].height == rightEyeTexture.height) {
                blitCommandEncoder.copy(from: textures[1], to: rightEyeTexture)
            } else {
                print("idx = \(idx)右眼RT(\(textures[1].width)-\(textures[1].height))----(\(rightEyeTexture.width)-\(rightEyeTexture.height))")
            }
        }
    }
    
    private func getNextSampleBuffer(_ time: CMTime, _ reader: AVAssetReader?, _ needHandleCompleted: Bool = true) -> CMSampleBuffer? {
        guard let assetReader = reader,
              let videoOutput = reader?.outputs.first else {
            print("Failed not found assetReader ")
            return nil
        }
        
        if assetReader.status == .completed {
            print("assetReader completed")
            if needHandleCompleted {
                playerDidFinishPlaying()
            }
            return nil
        }
        
        if assetReader.status != .reading {
            print("assetReader status = \(assetReader.status)")
            return nil
        }
        
        
        guard let nextSampleBuffer = videoOutput.copyNextSampleBuffer() else {
            return nil
        }
        
        let audioTime = time
        
        let tempVideoTime = CMSampleBufferGetPresentationTimeStamp(nextSampleBuffer)
        let videoTime = tempVideoTime
        
        let videoCurrent = CMTimeGetSeconds(videoTime)
        let audioCurrent = CMTimeGetSeconds(audioTime)
        
        let offset = videoCurrent - audioCurrent
        //        print("offset = \(offset)--idx:\(self.idx)--\(assetReader.asset)")
        if offset < -0.1 {
            while let nextBuffer = videoOutput.copyNextSampleBuffer() {
                let nextFrameTime = CMSampleBufferGetPresentationTimeStamp(nextBuffer)
                if CMTimeCompare(nextFrameTime, audioTime) >= 0 {
                    break
                }
            }
        } else if offset > 0.1 {
            return nil
        }
        
        return nextSampleBuffer
    }
    
    private func testRender(textures: [any MTLTexture],
                            secondTextures: [any MTLTexture]?,
                            blitCommandEncoder: any MTLBlitCommandEncoder,
                            commandBuffer: any MTLCommandBuffer) {
        
        if textures.count > 0 {
            testCopyTexture(textures, testLeftLayer, testRightLayer, blitCommandEncoder)
        }
        
        if secondTextures != nil && secondTextures!.count > 0 && testSecondLeftLayer != nil && testSecondRightLayer != nil {
            testCopyTexture(secondTextures!, testSecondLeftLayer, testSecondRightLayer, blitCommandEncoder)
        }
        
        blitCommandEncoder.endEncoding()
        
        testLeftLayer?.nextDrawable()?.present()
        testRightLayer?.nextDrawable()?.present()
        if secondTextures != nil {
            testSecondLeftLayer?.nextDrawable()?.present()
            testSecondRightLayer?.nextDrawable()?.present()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
    }
    
    private func testCopyTexture(_ textures: [any MTLTexture], _ leftLayer: CAMetalLayer?, _ rightLayer: CAMetalLayer?, _ blitCommandEncoder: any MTLBlitCommandEncoder) {
        let renderW = Int(leftLayer!.drawableSize.width)
        let renderH = Int(leftLayer!.drawableSize.height)
        
        let bufferW = textures.first!.width
        let bufferH = textures.first!.height
        
        
        let region = MTLRegionMake2D((bufferW - renderW) / 2, (bufferH - renderH) / 2, renderW, renderH)
        if let left = leftLayer?.nextDrawable() {
            blitCommandEncoder.copy(from: textures[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: left.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
        }
        
        if let right = rightLayer?.nextDrawable() {
            if textures.count > 1 {
                blitCommandEncoder.copy(from: textures[1], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: right.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            } else if textures.count == 1 {
                blitCommandEncoder.copy(from: textures[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: right.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            }
        }
    }
}


extension WLMp4Decoder { // 处理 texture
    func getTextures(cmSampleBuffer: CMSampleBuffer?) -> [MTLTexture]? {
        guard let cmSampleBuffer = cmSampleBuffer else { return nil }
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
