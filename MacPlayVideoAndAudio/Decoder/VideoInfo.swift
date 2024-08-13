//
//  VideoFileInfo.swift
//  testDecodemp4
//
//  Created by 赵强 on 2024/6/7.
//

import Foundation
import CoreMedia

class VideoInfo{
    @Published var width:Int = 4096
    @Published var height:Int = 2048
    @Published var isSpatial: Bool = false
    @Published var size: CGSize = .zero
    @Published var projectionType: CMProjectionType?
    @Published var horizontalFieldOfView: Float?
    @Published var fps: Int = 30

    var sizeString: String {
        size == .zero ? "unspecified" :
        String(format: "%.0fx%.0f", size.width, size.height) +
        (isSpatial ? " per eye" : "")
    }

    var projectionTypeString: String {
        projectionType.customMirror.description
    }
    
    var horizontalFieldOfViewString: String {
        horizontalFieldOfView.map { String(format: "%.0f°", $0) } ?? "unspecified"
    }
    init() {
        
    }

}
