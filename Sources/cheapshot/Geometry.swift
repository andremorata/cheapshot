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
