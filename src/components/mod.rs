//! The component ports this backend owns.
//!
//! One module per claimed view type: each registers its handler on the
//! dispatcher through [`crate::registry`]. Everything a module needs beyond
//! the [`crate::contract`] is a `cocoa-ui` addition, never a reactivity type
//! crossing into the kit.

#[cfg(feature = "badge")]
pub mod badge;
#[cfg(feature = "button")]
pub mod button;
#[cfg(feature = "color_picker")]
pub mod color_picker;
#[cfg(feature = "container")]
pub mod container;
#[cfg(feature = "date_picker")]
pub mod date_picker;
pub mod empty;
#[cfg(feature = "fixed_container")]
pub mod fixed_container;
#[cfg(feature = "focused")]
pub mod focused;
#[cfg(feature = "image")]
pub mod image;
#[cfg(feature = "layout_priority")]
pub mod layout_priority;
#[cfg(feature = "multi_date_picker")]
pub mod multi_date_picker;
#[cfg(feature = "navigation")]
pub mod navigation;
#[cfg(feature = "picker")]
pub mod picker;
#[cfg(feature = "plain")]
pub mod plain;
#[cfg(feature = "progress")]
pub mod progress;
#[cfg(feature = "resolved_color")]
pub mod resolved_color;
#[cfg(feature = "scroll")]
pub mod scroll;
#[cfg(feature = "secure_field")]
pub mod secure_field;
#[cfg(feature = "slider")]
pub mod slider;
#[cfg(feature = "spacer")]
pub mod spacer;
#[cfg(feature = "stepper")]
pub mod stepper;
#[cfg(feature = "table")]
pub mod table;
#[cfg(feature = "text")]
pub mod text;
#[cfg(feature = "text_field")]
pub mod text_field;
#[cfg(feature = "toggle")]
pub mod toggle;
