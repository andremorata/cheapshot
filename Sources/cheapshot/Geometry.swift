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
