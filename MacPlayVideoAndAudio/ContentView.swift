//
//  ContentView.swift
//  MacPlayVideoAndAudio
//
//  Created by welink on 2024/7/29.
//

import SwiftUI

@Observable class MetalLayerHolder {
    var metalLayer: CAMetalLayer?
}

class PlayUIView: NSView {
    
    override func makeBackingLayer() -> CALayer {
            let metalLayer = CAMetalLayer()
            metalLayer.device = MTLCreateSystemDefaultDevice()
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            return metalLayer
        }
    
//        override func makeBackingLayer() -> CALayer {
//            return CAMetalLayer()
//        }
}

struct PlayerView: NSViewRepresentable {
    @Binding var layerHolder: MetalLayerHolder
    
    func makeNSView(context: Context) -> NSView {
        let playUIView = PlayUIView()
        playUIView.wantsLayer = true
        playUIView.layer?.backgroundColor = NSColor.clear.cgColor
        
        if let layer = playUIView.layer as? CAMetalLayer {
            layerHolder.metalLayer = layer
        }
        
        return playUIView
    }
    
    func updateNSView(_ uiView: NSViewType, context: Context) {
        if let layer = uiView.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedDisplayP3)
            layer.framebufferOnly = false
        }
    }
}

struct ContentView: View {
    
    @State var decoder = WLMp4Decoder()
    @State var decoder2 = WLMp4Decoder()
    @State private var leftLayer = MetalLayerHolder()
    @State private var rightLayer = MetalLayerHolder()
    @State var w: CGFloat = 1280
    @State var h: CGFloat = 720
    var body: some View {
        ZStack {
            
            VStack {
                HStack {
                    Button("播放") {
                        play()
                    }
                    
                    Button("pause") {
                        decoder.pause()
                    }
                    
                    Button("resume") {
                        decoder.resume()
                    }
                    
                    Button("replay") {
                        decoder.rePlay()
                    }    
                }
                
                Spacer()
            }
            
            HStack {
                Spacer()
                PlayerView(layerHolder: $leftLayer)
                    .frame(width: w, height: h)
                
                PlayerView(layerHolder: $rightLayer)
                    .frame(width: w, height: h)
                Spacer()
            }
            .frame(width: 1920, height: 1080)
            //
            
        }
    }
}

extension ContentView {
    func play() {
        decoder.testLeftLayer = leftLayer.metalLayer
        decoder.testRightLayer = rightLayer.metalLayer
        
        decoder.play(url: Bundle.main.url(forResource: "db", withExtension: "mp4")!,
                     leftEyeTexture: leftLayer.metalLayer?.nextDrawable()?.texture,
                     rightEyeTexture: rightLayer.metalLayer?.nextDrawable()?.texture)
        
//        decoder2.play(url: Bundle.main.url(forResource: "730_1750_Music", withExtension: "mov")!,
//                     leftEyeTexture: leftLayer.metalLayer?.nextDrawable()?.texture,
//                     rightEyeTexture: rightLayer.metalLayer?.nextDrawable()?.texture)
    }
}


#Preview {
    ContentView()
}
