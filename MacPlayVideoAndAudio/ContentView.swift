//
//  ContentView.swift
//  MacPlayVideoAndAudio
//
//  Created by welink on 2024/7/29.
//

import SwiftUI
import CoreMedia


@Observable class MetalLayerHolder {
    var metalLayer: CAMetalLayer?
}

class PlayUIView: NSView {
    
    override func makeBackingLayer() -> CALayer {
            let metalLayer = CAMetalLayer()
            metalLayer.device = MTLCreateSystemDefaultDevice()
            metalLayer.pixelFormat = .bgr10_xr_srgb
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
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            layer.framebufferOnly = false
        }
    }
}

struct ContentView: View {
    
    @State var decoder = WLMp4Decoder()
    @State var decoder2 = WLMp4Decoder()
    @State private var leftLayer = MetalLayerHolder()
    @State private var rightLayer = MetalLayerHolder()
    
    @State private var leftLayer2 = MetalLayerHolder()
    @State private var rightLayer2 = MetalLayerHolder()
    
    @State var w: CGFloat = 4096
    @State var h: CGFloat = 2048
    var body: some View {
        ZStack {
            HStack {
                Spacer()
                PlayerView(layerHolder: $leftLayer)
                    .frame(width: w, height: h)
                
                PlayerView(layerHolder: $rightLayer)
                    .frame(width: w, height: h)
                
//                PlayerView(layerHolder: $leftLayer2)
//                    .frame(width: w, height: h)
//                
//                PlayerView(layerHolder: $rightLayer2)
//                    .frame(width: w, height: h)
                Spacer()
            }
            
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
                    
                    Button("seek") {
                        let time = CMTime(seconds: 50, preferredTimescale: 1)
                        decoder.seek(time: time)
                    }
                    
                    Button("seek2") {
                        let time = CMTime(seconds: 0, preferredTimescale: 1)
                        decoder.seek(time: time)
                    }
                }
                .padding()
                .background(.red)
                Spacer()
            }
            
            
        }
    }
}

extension ContentView {
    func play() {
        decoder.testLeftLayer = leftLayer.metalLayer
        decoder.testRightLayer = rightLayer.metalLayer
        
        decoder.play(url: Bundle.main.url(forResource: "fail", withExtension: "mov")!,
                     leftEyeTexture: leftLayer.metalLayer?.nextDrawable()?.texture,
                     rightEyeTexture: rightLayer.metalLayer?.nextDrawable()?.texture)
        
//        decoder2.testLeftLayer = leftLayer2.metalLayer
//        decoder2.testRightLayer = rightLayer2.metalLayer
//        decoder2.play(url: Bundle.main.url(forResource: "8151", withExtension: "mov")!,
//                     leftEyeTexture: leftLayer.metalLayer?.nextDrawable()?.texture,
//                     rightEyeTexture: rightLayer.metalLayer?.nextDrawable()?.texture)
    }
}


#Preview {
    ContentView()
}
