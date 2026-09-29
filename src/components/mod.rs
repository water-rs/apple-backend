//! The component ports this backend owns.
//!
//! One module per claimed view type: each registers its handler on the
//! dispatcher through [`crate::registry`]. Everything a module needs beyond
//! the [`crate::contract`] is a `cocoa-ui` addition, never a reactivity type
//! crossing into the kit.

#[cfg(feature = "button")]
pub mod button;
#[cfg(feature = "color_picker")]
pub mod color_picker;
pub mod empty;
#[cfg(feature = "focused")]
pub mod focused;
#[cfg(feature = "image")]
pub mod image;
#[cfg(feature = "picker")]
pub mod picker;
#[cfg(feature = "progress")]
pub mod progress;
#[cfg(feature = "secure_field")]
pub mod secure_field;
#[cfg(feature = "slider")]
pub mod slider;
#[cfg(feature = "spacer")]
pub mod spacer;
#[cfg(feature = "stepper")]
pub mod stepper;
#[cfg(feature = "text")]
pub mod text;
#[cfg(feature = "text_field")]
pub mod text_field;
#[cfg(feature = "toggle")]
pub mod toggle;
