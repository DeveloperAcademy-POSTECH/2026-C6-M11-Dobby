import Foundation
import CoreGraphics
import ImageIO
import Vision

// Candidate-free local OCR. No brand dictionary, custom words, or network.
func rotated(_ image: CGImage, degrees: Int) -> CGImage? {
    if degrees == 0 { return image }
    let radians = CGFloat(degrees) * .pi / 180
    let width = Int(ceil(abs(CGFloat(image.width) * cos(radians)) + abs(CGFloat(image.height) * sin(radians))))
    let height = Int(ceil(abs(CGFloat(image.width) * sin(radians)) + abs(CGFloat(image.height) * cos(radians))))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    context.rotate(by: radians)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
        width: CGFloat(image.width), height: CGFloat(image.height)))
    return context.makeImage()
}

guard CommandLine.arguments.count == 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    exit(1)
}
var readings: [[String: Any]] = []
for degrees in stride(from: 0, to: 360, by: 45) {
    try autoreleasepool {
        guard let input = rotated(image, degrees: degrees) else { return }
        let request = VNRecognizeTextRequest()
        request.usesCPUOnly = true
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.015
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.3 else { continue }
            readings.append(["rotationDegrees": degrees, "text": String(candidate.string.prefix(300)),
                "confidence": candidate.confidence])
        }
        // Flush completed orientations so the local time budget can preserve
        // useful OCR even if a later orientation is slow.
        let progress = try JSONSerialization.data(withJSONObject: ["readings": readings])
        FileHandle.standardOutput.write(progress)
        FileHandle.standardOutput.write(Data([10]))
    }
}
let data = try JSONSerialization.data(withJSONObject: ["readings": readings])
FileHandle.standardOutput.write(data)
