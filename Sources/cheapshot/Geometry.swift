import CoreGraphics

/// AppKit puts the origin at the bottom-left of the primary screen. ScreenCaptureKit and
/// CGWindowList put it at the top-left. `primaryHeight` is the primary screen's height in points.
func flipY(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// Moves a rect from global top-left coordinates into the space of the display that holds it.
func displayLocal(_ rect: CGRect, displayFrame: CGRect) -> CGRect {
    rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
}

/// Scales `size` to fit inside `rect`, centered, keeping its proportions. `maxScale` caps the growth.
func aspectFit(_ size: CGSize, in rect: CGRect, maxScale: CGFloat = .infinity) -> CGRect {
    // `insetBy` returns the null rect when a view is smaller than its margins.
    guard size.width > 0, size.height > 0, !rect.isEmpty else { return .zero }
    let scale = min(rect.width / size.width, rect.height / size.height, maxScale)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
}

/// Turns a crop in image points (bottom-left origin) into the pixel rect `CGImage.cropping`
/// expects (top-left origin). `imageHeight` is the full image height in points.
func pixelRect(forCrop crop: CGRect, imageHeight: CGFloat, scale: CGFloat) -> CGRect {
    CGRect(x: crop.minX * scale, y: (imageHeight - crop.maxY) * scale, width: crop.width * scale, height: crop.height * scale)
        .integral
}

/// Where the size label and the loupe sit around the pointer, in top-left coordinates: the label
/// up and to the left, the loupe down and to the left. Each moves to the other side when a screen
/// edge is in the way. `loupe` is its diameter, and 0 leaves it out.
func pointerCompanions(at pointer: CGPoint, label: CGSize, loupe: CGFloat, in bounds: CGRect) -> (label: CGRect, loupe: CGRect) {
    let gap: CGFloat = 14
    func x(_ width: CGFloat) -> CGFloat {
        let left = pointer.x - gap - width
        return left < bounds.minX ? pointer.x + gap : left
    }
    var labelY = pointer.y - gap - label.height
    var loupeY = pointer.y + gap
    // No room below: the loupe goes above the label.
    if loupeY + loupe > bounds.maxY { loupeY = labelY - 6 - loupe }
    // No room above: the label goes under the loupe.
    if labelY < bounds.minY { labelY = loupeY + loupe + 6 }
    return (
        CGRect(x: x(label.width), y: labelY, width: label.width, height: label.height),
        CGRect(x: x(loupe), y: loupeY, width: loupe, height: loupe))
}

/// Snaps `point` to the horizontal or vertical line through `anchor`, whichever is closer.
func axisLocked(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
    abs(point.x - anchor.x) >= abs(point.y - anchor.y)
        ? CGPoint(x: point.x, y: anchor.y)
        : CGPoint(x: anchor.x, y: point.y)
}

/// Moves `point` so the box from `anchor` to it is a square, keeping the direction of the drag.
func squared(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
    let dx = point.x - anchor.x
    let dy = point.y - anchor.y
    let side = max(abs(dx), abs(dy))
    return CGPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
}

/// Rounds a length down to an even number of pixels, which video codecs require. Never below 2.
func evenPixels(_ length: CGFloat) -> Int {
    max(Int(length) / 2 * 2, 2)
}

/// The box from `anchor`, which stays put, toward `point`. It stays inside `bounds` and is at
/// least `minimum` long on each side. With `ratio`, width over height, it keeps that shape.
func cropRect(from anchor: CGPoint, to point: CGPoint, ratio: CGFloat?, in bounds: CGRect, minimum: CGFloat) -> CGRect {
    // A side too near the edge for the minimum grows the other way instead.
    func direction(_ delta: CGFloat, before: CGFloat, after: CGFloat, needs: CGFloat) -> CGFloat {
        if delta < 0, before >= needs { return -1 }
        return after >= needs ? 1 : -1
    }
    let minWidth = max(minimum, minimum * (ratio ?? 1))
    let minHeight = max(minimum, minimum / (ratio ?? 1))
    let dx = point.x - anchor.x
    let dy = point.y - anchor.y
    let right = direction(dx, before: anchor.x - bounds.minX, after: bounds.maxX - anchor.x, needs: minWidth)
    let down = direction(dy, before: anchor.y - bounds.minY, after: bounds.maxY - anchor.y, needs: minHeight)
    let roomX = right > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
    let roomY = down > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY

    var width = max(abs(dx), minWidth)
    var height = max(abs(dy), minHeight)
    if let ratio {
        width = min(max(width, height * ratio), roomX, roomY * ratio)
        height = width / ratio
    } else {
        width = min(width, roomX)
        height = min(height, roomY)
    }
    return CGRect(
        x: right > 0 ? anchor.x : anchor.x - width, y: down > 0 ? anchor.y : anchor.y - height,
        width: width, height: height)
}

/// Whole pixels for the origin and even ones for the size, which video codecs require. The result
/// stays inside any whole-pixel bounds that held `rect`.
func evenPixelRect(_ rect: CGRect) -> CGRect {
    let x = rect.minX.rounded()
    let y = rect.minY.rounded()
    return CGRect(x: x, y: y, width: CGFloat(evenPixels(rect.maxX.rounded() - x)), height: CGFloat(evenPixels(rect.maxY.rounded() - y)))
}
