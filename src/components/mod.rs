//! The component ports this backend owns.
//!
//! One module per claimed view type: each registers its handler on the
//! dispatcher through [`crate::registry`]. Everything a module needs beyond
//! the [`crate::contract`] is a `cocoa-ui` addition, never a reactivity type
//! crossing into the kit.

#[cfg(feature = "image")]
pub mod image;
#[cfg(feature = "text")]
pub mod text;
