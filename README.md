# WaterUI Apple Backend

[![License](https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-blue.svg)](#license)

This repository contains the native Apple backend for the [WaterUI framework](https://github.com/water-rs/waterui), implemented in Swift and leveraging UIKit/AppKit.

## Overview

WaterUI is a modern, cross-platform UI framework implemented in Rust. This backend renders the UI declared in a WaterUI application on Apple platforms (iOS, macOS, iPadOS).

It consumes FFI-friendly view descriptions from the Rust core and renders them using native UIKit/AppKit components. The framework is designed for declarative composition, fine-grained reactivity, and native performance.


## Building

To build the project, you can use the Swift Package Manager:

```bash
swift build
```

To use this backend, it must be integrated with the main WaterUI application. Please see the main [WaterUI repository](https://github.com/waterui/waterui) for instructions on building a complete application.

## Contributing

Contributions are welcome! Please feel free to submit a pull request or open an issue if you find a bug or have a feature request.