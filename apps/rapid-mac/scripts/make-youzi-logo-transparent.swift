#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LogoError: Error, CustomStringConvertible {
    case usage
    case unreadableImage(String)
    case unsupportedImage
    case contextCreation
    case outputCreation(String)
    case writeFailed

    var description: String {
        switch self {
        case .usage:
            return "usage: make-youzi-logo-transparent.swift INPUT.png OUTPUT.png"
        case let .unreadableImage(path):
            return "unable to read PNG: \(path)"
        case .unsupportedImage:
            return "input image has unsupported dimensions"
        case .contextCreation:
            return "unable to create RGBA bitmap context"
        case let .outputCreation(path):
            return "unable to create output PNG: \(path)"
        case .writeFailed:
            return "unable to write transparent PNG"
        }
    }
}

func isWarmCanvas(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
    let red = Int(r)
    let green = Int(g)
    let blue = Int(b)

    // The source artwork uses a very light warm canvas. Restrict the mask to
    // bright, low-chroma pixels and then flood from the image border, so the
    // enclosed pale fruit interior remains part of the mark.
    return red >= 238
        && green >= 228
        && blue >= 205
        && red - green <= 32
        && green - blue <= 36
        && red - blue <= 60
}

func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw LogoError.usage
    }

    let inputPath = CommandLine.arguments[1]
    let outputPath = CommandLine.arguments[2]
    let inputURL = URL(fileURLWithPath: inputPath)
    let outputURL = URL(fileURLWithPath: outputPath)

    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw LogoError.unreadableImage(inputPath)
    }

    let width = image.width
    let height = image.height
    guard width > 1, height > 1 else {
        throw LogoError.unsupportedImage
    }

    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue

    let drewImage = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let context = CGContext(
            data: rawBuffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drewImage else {
        throw LogoError.contextCreation
    }

    let pixelCount = width * height
    var background = [Bool](repeating: false, count: pixelCount)
    var queue = [Int]()
    queue.reserveCapacity(pixelCount)

    func enqueue(_ index: Int) {
        guard !background[index] else { return }
        let byte = index * 4
        guard isWarmCanvas(pixels[byte], pixels[byte + 1], pixels[byte + 2]) else {
            return
        }
        background[index] = true
        queue.append(index)
    }

    for x in 0..<width {
        enqueue(x)
        enqueue((height - 1) * width + x)
    }
    for y in 0..<height {
        enqueue(y * width)
        enqueue(y * width + width - 1)
    }

    var head = 0
    while head < queue.count {
        let index = queue[head]
        head += 1
        let x = index % width
        let y = index / width
        if x > 0 { enqueue(index - 1) }
        if x + 1 < width { enqueue(index + 1) }
        if y > 0 { enqueue(index - width) }
        if y + 1 < height { enqueue(index + width) }
    }

    // Remove one source-resolution fringe pixel. The product renders the
    // 1254 px master at much smaller sizes, so this prevents a warm halo on
    // dark themes while preserving the silhouette and all enclosed details.
    var transparent = background
    for index in background.indices where background[index] {
        let x = index % width
        let y = index / width
        if x > 0 { transparent[index - 1] = true }
        if x + 1 < width { transparent[index + 1] = true }
        if y > 0 { transparent[index - width] = true }
        if y + 1 < height { transparent[index + width] = true }
    }

    var transparentCount = 0
    for index in transparent.indices {
        let byte = index * 4
        if transparent[index] {
            pixels[byte] = 0
            pixels[byte + 1] = 0
            pixels[byte + 2] = 0
            pixels[byte + 3] = 0
            transparentCount += 1
        } else {
            pixels[byte + 3] = 255
        }
    }

    let outputImage: CGImage? = pixels.withUnsafeMutableBytes { rawBuffer in
        guard let context = CGContext(
            data: rawBuffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        return context.makeImage()
    }
    guard let outputImage else {
        throw LogoError.contextCreation
    }

    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw LogoError.outputCreation(outputPath)
    }
    CGImageDestinationAddImage(destination, outputImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw LogoError.writeFailed
    }

    let percentage = Double(transparentCount) / Double(pixelCount) * 100
    print(
        "wrote \(outputPath): \(width)x\(height), "
            + String(format: "%.1f%% transparent", percentage)
    )
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
