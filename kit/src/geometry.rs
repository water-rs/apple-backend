//! Points, sizes, rectangles and insets, in points (not pixels).
//!
//! These are plain values shared by both platforms, and convert to and from
//! the Core Graphics types the frameworks use.

use objc2_core_foundation::{CGPoint, CGRect, CGSize};

/// A location in a two-dimensional coordinate space.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point {
    /// The horizontal coordinate.
    pub x: f64,
    /// The vertical coordinate.
    pub y: f64,
}

impl Point {
    /// The origin, `(0, 0)`.
    pub const ZERO: Self = Self::new(0.0, 0.0);

    /// A point at `(x, y)`.
    #[must_use]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// A width and a height.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Size {
    /// The horizontal extent.
    pub width: f64,
    /// The vertical extent.
    pub height: f64,
}

impl Size {
    /// A size with no extent.
    pub const ZERO: Self = Self::new(0.0, 0.0);

    /// A size of `width` by `height`.
    #[must_use]
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

/// A rectangle: an origin and a size.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    /// The corner the rectangle extends from.
    pub origin: Point,
    /// How far the rectangle extends from its origin.
    pub size: Size,
}

impl Rect {
    /// The empty rectangle at the origin.
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0, 0.0);

    /// A rectangle at `(x, y)` of `width` by `height`.
    #[must_use]
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            origin: Point::new(x, y),
            size: Size::new(width, height),
        }
    }
}

/// Distances inward from each edge of a rectangle.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct EdgeInsets {
    /// The inset from the top edge.
    pub top: f64,
    /// The inset from the left edge.
    pub left: f64,
    /// The inset from the bottom edge.
    pub bottom: f64,
    /// The inset from the right edge.
    pub right: f64,
}

impl EdgeInsets {
    /// No inset on any edge.
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0, 0.0);

    /// Insets of `top`, `left`, `bottom` and `right`.
    #[must_use]
    pub const fn new(top: f64, left: f64, bottom: f64, right: f64) -> Self {
        Self {
            top,
            left,
            bottom,
            right,
        }
    }
}

impl From<CGPoint> for Point {
    fn from(point: CGPoint) -> Self {
        Self::new(point.x, point.y)
    }
}

impl From<Point> for CGPoint {
    fn from(point: Point) -> Self {
        Self::new(point.x, point.y)
    }
}

impl From<CGSize> for Size {
    fn from(size: CGSize) -> Self {
        Self::new(size.width, size.height)
    }
}

impl From<Size> for CGSize {
    fn from(size: Size) -> Self {
        Self::new(size.width, size.height)
    }
}

impl From<CGRect> for Rect {
    fn from(rect: CGRect) -> Self {
        Self {
            origin: rect.origin.into(),
            size: rect.size.into(),
        }
    }
}

impl From<Rect> for CGRect {
    fn from(rect: Rect) -> Self {
        Self::new(rect.origin.into(), rect.size.into())
    }
}

#[cfg(test)]
mod tests {
    use super::{Point, Rect, Size};
    use objc2_core_foundation::{CGPoint, CGRect, CGSize};

    #[test]
    fn rect_round_trips_through_core_graphics() {
        let rect = Rect::new(1.5, -2.0, 800.0, 600.25);
        let native = CGRect::from(rect);
        assert_eq!(native.origin, CGPoint::new(1.5, -2.0));
        assert_eq!(native.size, CGSize::new(800.0, 600.25));
        assert_eq!(Rect::from(native), rect);
    }

    #[test]
    fn point_and_size_keep_their_components() {
        assert_eq!(Point::from(CGPoint::new(3.0, 4.0)), Point::new(3.0, 4.0));
        assert_eq!(Size::from(CGSize::new(5.0, 6.0)), Size::new(5.0, 6.0));
        assert_eq!(Rect::ZERO, Rect::default());
    }
}
