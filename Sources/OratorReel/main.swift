import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import OratorKit

// Not shipped. Renders the notch indicator's dictation lifecycle to assets/reel.mp4 (+ .gif):
// idle → the panel SPRINGS out of the notch (scale from the top, the menu-bar icon crossfading
// white→orange) → live waveform + streaming preview → the leading orb morphs waveform→spinner on
// finalize → insert → the panel eases closed. The opaque physical notch (camera housing) is drawn on
// top so all content is seen to sit BELOW it (ORA-IND-011). Spring/ease feel mirrors the live view.

let LOGICAL = CGSize(width: 620, height: 190)
let SCALE: CGFloat = 2
let FPS = 30
// Lifecycle frame boundaries (cumulative).
let tExpand   = 12       // idle hold (collapsed, white icon)
let tRec      = 32       // + spring open (~0.67 s: visible rise + settle)
let tFinal    = 92       // + recording / streaming (~2 s)
let tInsert   = 116      // + finalizing (waveform→spinner)
let tCollapse = 124      // + inserting
let tIdleEnd  = 138      // + ease closed (~0.47 s)
let TOTAL     = 146      // + idle hold before the loop repeats

let PHYS_NOTCH = CGSize(width: 185, height: 32)   // 14-inch physical notch
let NOTCH_BAND: CGFloat = 32
let MIN_SCALE = 0.12     // collapsed: a sliver hidden behind the notch (matches the live view)

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
// Underdamped spring step-response for the OPEN — the `.snappy` feel: a quick rise, a small
// overshoot, then settle (ζ≈0.72 → ~3% overshoot). Smooth, no-overshoot easeInOut for the CLOSE.
func springOpen(_ t: Double) -> Double {
    let x = clamp(t), zeta = 0.72, omega = 8.5
    let omegaD = omega * (1 - zeta * zeta).squareRoot()
    let decay = exp(-zeta * omega * x)
    return 1 - decay * (cos(omegaD * x) + (zeta * omega / omegaD) * sin(omegaD * x))
}
func easeInOut(_ t: Double) -> Double { let x = clamp(t); return x < 0.5 ? 4*x*x*x : 1 - pow(-2*x + 2, 3) / 2 }
let sentence = "the quick brown fox jumped over the lazy dog"

/// The opaque camera housing. Content must never render here (ORA-IND-011).
struct PhysicalNotch: View {
    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(Color.black)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.white.opacity(0.05)).frame(height: 1)   // hint the housing edge
                }
            // camera lens
            Circle().fill(Color(white: 0.05))
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(Color(white: 0.22), lineWidth: 1))
                .padding(.top, 12)
        }
        .frame(width: PHYS_NOTCH.width, height: PHYS_NOTCH.height)
    }
}

struct ReelScene: View {
    let i: Int

    private var state: SessionState {
        if i < tFinal { return .recording }
        if i < tInsert { return .finalizing }
        return .inserting
    }
    // Panel transform: spring OPEN (scale from the top, subtle overshoot), hold, then ease CLOSED —
    // the "notch stretches open / seals shut" feel of the live view (ORA-IND-011/018).
    private var scale: CGFloat {
        if i < tExpand { return MIN_SCALE }
        if i < tRec { return MIN_SCALE + (1 - MIN_SCALE) * springOpen(Double(i - tExpand) / Double(tRec - tExpand)) }
        if i < tCollapse { return 1 }
        if i < tIdleEnd { return 1 - (1 - MIN_SCALE) * easeInOut(Double(i - tCollapse) / Double(tIdleEnd - tCollapse)) }
        return MIN_SCALE
    }
    private var alpha: Double {
        if i < tExpand { return 0 }
        if i < tExpand + 4 { return clamp(Double(i - tExpand) / 4) }
        if i < tCollapse { return 1 }
        if i < tIdleEnd { return 1 - clamp(Double(i - tCollapse) / Double(tIdleEnd - tCollapse)) }
        return 0
    }
    // Menu-bar icon crossfades white(0)→orange(1) with the open, back to white with the close.
    private var iconTint: Double {
        if i < tExpand { return 0 }
        if i < tRec { return clamp(Double(i - tExpand) / Double(tRec - tExpand)) }
        if i < tCollapse { return 1 }
        if i < tIdleEnd { return 1 - clamp(Double(i - tCollapse) / Double(tIdleEnd - tCollapse)) }
        return 0
    }
    private var iconColor: Color { Color(red: 1, green: 1 - 0.416 * iconTint, blue: 1 - iconTint) }
    private var morph: Double { i < tFinal ? 0 : clamp(Double(i - tFinal) / 8) }
    private var levels: [Float] {
        // Speech-like VU bars: each bar bounces on its own height, refreshed ~10 Hz (matching the live
        // 100 ms level cadence) — NOT a flowing sine. A slow envelope stands in for syllables.
        let step = Double(i / 3)                                    // hold 3 frames ≈ the live update rate
        let env = 0.4 + 0.6 * abs(sin(step * 0.6))
        func rand(_ a: Double) -> Double { let x = sin(a) * 43758.5453; return x - x.rounded(.down) }
        return (0..<IndicatorMetrics.barCount).map { j in
            Float(0.18 + 0.82 * env * rand(step * 3.3 + Double(j) * 17.1))
        }
    }
    private var previewTail: String {
        guard state == .recording, i >= tRec else { return "" }
        // Finish streaming ~10 frames before the stop so the FULL sentence is briefly visible before it
        // hands off to "Transcribing…" → "Inserting text…".
        let p = clamp(Double(i - tRec) / Double(tFinal - tRec - 10))
        return String(sentence.prefix(Int((Double(sentence.count) * p).rounded())))
    }
    private var content: IndicatorContent {
        IndicatorContent(state: state,
                         elapsed: Double(max(0, i - tExpand)) / Double(FPS),
                         level: 0.6, levels: levels, previewTail: previewTail,
                         isNotch: true, notchBand: NOTCH_BAND,
                         morph: morph, staticClock: Double(i) / Double(FPS))
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.09, green: 0.11, blue: 0.26),
                                    Color(red: 0.28, green: 0.15, blue: 0.34)],
                           startPoint: .top, endPoint: .bottom)
            // Menu bar (the waveform icon crossfades white→orange while dictating).
            ZStack {
                Rectangle().fill(.black.opacity(0.30)).frame(height: NOTCH_BAND)
                HStack {
                    Image(systemName: "apple.logo").foregroundStyle(.white)
                    Text("Editor").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "waveform").foregroundStyle(iconColor)
                    Text("9:41").font(.system(size: 13)).foregroundStyle(.white)
                }.padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            // Indicator panel — springs out of the notch (scale from the top), content BELOW the band.
            IndicatorView(content: content)
                .scaleEffect(scale, anchor: .top)
                .opacity(alpha)
            // Opaque physical notch on top (camera housing) — proves content sits below it.
            PhysicalNotch()
        }
        .frame(width: LOGICAL.width, height: LOGICAL.height)
    }
}

@MainActor func renderFrames() -> [CGImage] {
    (0..<TOTAL).compactMap { i in
        let r = ImageRenderer(content: ReelScene(i: i)); r.scale = SCALE
        return r.cgImage
    }
}

func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
    let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb)
    guard let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

func writeMP4(_ frames: [CGImage], to url: URL) -> Bool {
    guard let first = frames.first else { return false }
    let w = first.width, h = first.height
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                      kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)
    for (i, img) in frames.enumerated() {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        if let pb = pixelBuffer(from: img, width: w, height: h) {
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(FPS)))
        }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    return writer.status == .completed
}

func writeGIF(_ frames: [CGImage], to url: URL) -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
    else { return false }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String:
        [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary as String:
        [kCGImagePropertyGIFDelayTime as String: 1.0 / Double(FPS)]] as CFDictionary
    for img in frames { CGImageDestinationAddImage(dest, img, frameProps) }
    return CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    let frames = renderFrames()
    print("rendered \(frames.count) frames at \(Int(LOGICAL.width * SCALE))×\(Int(LOGICAL.height * SCALE))")
    print(writeMP4(frames, to: URL(fileURLWithPath: "\(outDir)/reel.mp4")) ? "wrote reel.mp4" : "mp4 failed")
    print(writeGIF(frames, to: URL(fileURLWithPath: "\(outDir)/reel.gif")) ? "wrote reel.gif" : "gif failed")
}
