import CoreGraphics
import Foundation
import ImageIO

/// How much of the screen changed between two captures, so a click that did nothing can say so. A bot clicking the wrong spot (or a page
/// that ignores the click) otherwise gets `ok: true` and a screenshot that looks the same, and tries the same thing again.
public enum ScreenDiff {
    /// Fraction (0...1) of a coarse grid whose brightness moved by more than a small amount, or nil if either image can't be read.
    public static func changedFraction(_ a: Data, _ b: Data, grid: (w: Int, h: Int) = (160, 100), threshold: Int = 24) -> Double? {
        guard let x = pixels(a, grid), let y = pixels(b, grid), x.count == y.count, !x.isEmpty else { return nil }
        var changed = 0
        for i in x.indices where abs(Int(x[i]) - Int(y[i])) > threshold { changed += 1 }
        return Double(changed) / Double(x.count)
    }

    /// Below this, the screen did not react: the pointer's own hover effects and a blinking text cursor stay under it.
    public static let reactionThreshold = 0.004

    private static func pixels(_ data: Data, _ grid: (w: Int, h: Int)) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let ctx = CGContext(data: nil, width: grid.w, height: grid.h, bitsPerComponent: 8, bytesPerRow: grid.w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: grid.w, height: grid.h))
        guard let base = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: grid.w * grid.h))
    }
}

/// The last capture of each sandbox's screen, to compare the next one with.
final class ScreenMemory: @unchecked Sendable {
    static let shared = ScreenMemory()
    private let lock = NSLock()
    private var last: [String: Data] = [:]
    /// Stores `data` as the latest capture of `sandboxID`; returns how much of the screen changed since the one before, if there was one.
    func record(_ data: Data, for sandboxID: String) -> Double? {
        lock.lock(); let previous = last[sandboxID]; last[sandboxID] = data; lock.unlock()
        return previous.flatMap { ScreenDiff.changedFraction($0, data) }
    }
}
