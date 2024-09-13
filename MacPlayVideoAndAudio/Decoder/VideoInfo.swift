//
//  VideoInfo.swift
//  SpatialPlayer
//
//  Created by Michael Swanson on 2/6/24.
//

import Foundation
import CoreMedia

class VideoInfo {
    @Published var isSpatial: Bool = false
    @Published var size: CGSize = .zero
    @Published var projectionType: CMProjectionType?
    @Published var horizontalFieldOfView: Float?
    @Published var fps: Float = 60.0
    @Published var url: URL?
    @Published var asset: AVAsset?
    @Published var videoTrack: AVAssetTrack?
    @Published var colorPrimaries: String?
    @Published var transferFunction: String?
    @Published var yCbCrMatrix: String?
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
}
