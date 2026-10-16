import CoreGraphics
import Foundation

/// 縁の強さ（エッジ保持フェザーの半径）。
enum EdgeSoftness: String, CaseIterable, Identifiable {
    case none
    case weak
    case medium
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "なし"
        case .weak: return "弱"
        case .medium: return "中"
        case .strong: return "強"
        }
    }

    /// 12MP（長辺 4032px）の写真での半径。写真の大きさに比例させる。
    func radius(forLongSide longSide: Int) -> Int {
        let base: Double
        switch self {
        case .none: return 0
        case .weak: base = 4
        case .medium: base = 8
        case .strong: base = 16
        }
        return max(1, Int((base * Double(longSide) / 4032).rounded()))
    }
}

/// マスクの縁を元写真の明るさに沿ってなめらかにする（モヘアなどの毛羽対策）。
///
/// ガイデッドフィルタ（元写真の輝度をガイドにする）を縮小画像で計算し、
/// 縁の近く（マスクが 0 と 255 の境目付近）だけに適用する。縁から離れた作品の内側・背景は変えない。
enum EdgeRefiner {
    static func feather(mask: AlphaMask, guide: RGBAImage, radius: Int, epsilon: Float = 5e-4) -> AlphaMask {
        precondition(mask.width == guide.width && mask.height == guide.height)
        guard radius > 0 else { return mask }
        let width = mask.width
        let height = mask.height
        let step = radius >= 4 ? 4 : 1
        let lowRadius = max(1, radius / step)
        let lw = (width + step - 1) / step
        let lh = (height + step - 1) / step

        // 縮小（面積平均）
        var lowGuide = [Float](repeating: 0, count: lw * lh)
        var lowMask = [Float](repeating: 0, count: lw * lh)
        var counts = [Float](repeating: 0, count: lw * lh)
        guide.pixels.withUnsafeBufferPointer { pixels in
            mask.values.withUnsafeBufferPointer { values in
                for y in 0..<height {
                    let ly = y / step
                    for x in 0..<width {
                        let li = ly * lw + x / step
                        let i = y * width + x
                        lowGuide[li] += luminance(pixels, i)
                        lowMask[li] += Float(values[i]) / 255
                        counts[li] += 1
                    }
                }
            }
        }
        for i in 0..<(lw * lh) {
            lowGuide[i] /= counts[i]
            lowMask[i] /= counts[i]
        }

        // ガイデッドフィルタの係数
        let meanI = boxMean(lowGuide, width: lw, height: lh, radius: lowRadius)
        let meanP = boxMean(lowMask, width: lw, height: lh, radius: lowRadius)
        let corrII = boxMean(zip(lowGuide, lowGuide).map { $0 * $1 }, width: lw, height: lh, radius: lowRadius)
        let corrIP = boxMean(zip(lowGuide, lowMask).map { $0 * $1 }, width: lw, height: lh, radius: lowRadius)
        var a = [Float](repeating: 0, count: lw * lh)
        var b = [Float](repeating: 0, count: lw * lh)
        for i in 0..<(lw * lh) {
            let variance = corrII[i] - meanI[i] * meanI[i]
            let covariance = corrIP[i] - meanI[i] * meanP[i]
            a[i] = covariance / (variance + epsilon)
            b[i] = meanP[i] - a[i] * meanI[i]
        }
        let meanA = boxMean(a, width: lw, height: lh, radius: lowRadius)
        let meanB = boxMean(b, width: lw, height: lh, radius: lowRadius)

        // 元の解像度で、縁の近くだけ置き換える
        var output = mask.values
        guide.pixels.withUnsafeBufferPointer { pixels in
            for y in 0..<height {
                let v = (Float(y) + 0.5) / Float(step) - 0.5
                for x in 0..<width {
                    let u = (Float(x) + 0.5) / Float(step) - 0.5
                    let band = sample(meanP, lw, lh, u, v)
                    guard band > 0.002, band < 0.998 else { continue }
                    let i = y * width + x
                    let q = sample(meanA, lw, lh, u, v) * luminance(pixels, i) + sample(meanB, lw, lh, u, v)
                    output[i] = AlphaMask.quantize(q)
                }
            }
        }
        return AlphaMask(width: width, height: height, values: output)
    }

    @inline(__always)
    private static func luminance(_ pixels: UnsafeBufferPointer<UInt8>, _ index: Int) -> Float {
        let base = index * 4
        return (0.299 * Float(pixels[base]) + 0.587 * Float(pixels[base + 1]) + 0.114 * Float(pixels[base + 2])) / 255
    }

    /// 双一次補間（範囲外は端の値）。
    @inline(__always)
    private static func sample(_ values: [Float], _ w: Int, _ h: Int, _ u: Float, _ v: Float) -> Float {
        let cu = min(max(u, 0), Float(w - 1))
        let cv = min(max(v, 0), Float(h - 1))
        let x0 = Int(cu)
        let y0 = Int(cv)
        let x1 = min(x0 + 1, w - 1)
        let y1 = min(y0 + 1, h - 1)
        let fx = cu - Float(x0)
        let fy = cv - Float(y0)
        let top = values[y0 * w + x0] * (1 - fx) + values[y0 * w + x1] * fx
        let bottom = values[y1 * w + x0] * (1 - fx) + values[y1 * w + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    /// 半径 r の箱型平均（端は窓に入る画素だけで平均する）。
    static func boxMean(_ input: [Float], width: Int, height: Int, radius r: Int) -> [Float] {
        var horizontal = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            var count: Float = 0
            for x in 0..<min(r, width) {
                sum += input[row + x]
                count += 1
            }
            for x in 0..<width {
                let add = x + r
                if add < width {
                    sum += input[row + add]
                    count += 1
                }
                let remove = x - r - 1
                if remove >= 0 {
                    sum -= input[row + remove]
                    count -= 1
                }
                horizontal[row + x] = sum / count
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        for x in 0..<width {
            var sum: Float = 0
            var count: Float = 0
            for y in 0..<min(r, height) {
                sum += horizontal[y * width + x]
                count += 1
            }
            for y in 0..<height {
                let add = y + r
                if add < height {
                    sum += horizontal[add * width + x]
                    count += 1
                }
                let remove = y - r - 1
                if remove >= 0 {
                    sum -= horizontal[remove * width + x]
                    count -= 1
                }
                output[y * width + x] = sum / count
            }
        }
        return output
    }
}

/// ブラシでマスクを塗る。変えた画素を記録しておき、1ストローク単位で取り消せる。
struct MaskStroke {
    var indices: [Int32] = []
    var previous: [UInt8] = []
}

extension AlphaMask {
    /// from から to まで、半径 radius（画素）の円を並べて塗る。add なら作品に追加、そうでなければ消去。
    @discardableResult
    mutating func paint(from start: CGPoint, to end: CGPoint, radius: Double, add: Bool,
                        recordingInto stroke: inout MaskStroke) -> CGRect {
        let target: UInt8 = add ? 255 : 0
        let r = max(0.5, radius)
        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        let steps = max(1, Int(distance / max(1, r / 3)))
        let r2 = r * r
        var dirty = CGRect.null

        for s in 0...steps {
            let t = Double(s) / Double(steps)
            let cx = Double(start.x) + dx * t
            let cy = Double(start.y) + dy * t
            let minX = max(0, Int((cx - r).rounded(.down)))
            let maxX = min(width - 1, Int((cx + r).rounded(.up)))
            let minY = max(0, Int((cy - r).rounded(.down)))
            let maxY = min(height - 1, Int((cy + r).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                let ddy = Double(y) + 0.5 - cy
                for x in minX...maxX {
                    let ddx = Double(x) + 0.5 - cx
                    guard ddx * ddx + ddy * ddy <= r2 else { continue }
                    let i = y * width + x
                    let old = values[i]
                    if old != target {
                        stroke.indices.append(Int32(i))
                        stroke.previous.append(old)
                        values[i] = target
                    }
                }
            }
            dirty = dirty.union(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
        return dirty
    }

    mutating func undo(_ stroke: MaskStroke) {
        for k in stroke.indices.indices.reversed() {
            values[Int(stroke.indices[k])] = stroke.previous[k]
        }
    }

    /// 表示用に縮小する（最近傍）。
    func downscaled(maxDimension: Int) -> AlphaMask {
        let factor = min(1, Double(maxDimension) / Double(max(width, height)))
        let w = max(1, Int((Double(width) * factor).rounded()))
        let h = max(1, Int((Double(height) * factor).rounded()))
        var output = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let sy = min(height - 1, Int((Double(y) + 0.5) / factor))
            for x in 0..<w {
                let sx = min(width - 1, Int((Double(x) + 0.5) / factor))
                output[y * w + x] = values[sy * width + sx]
            }
        }
        return AlphaMask(width: w, height: h, values: output)
    }
}
