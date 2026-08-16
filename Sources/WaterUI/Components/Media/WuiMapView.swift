// WuiMapView.swift
// Map component - MKMapView wrapper for WaterUI
//
// # Layout Behavior
// MapView is greedy - it expands to fill all available space.

#if WATERUI_MAP

import CWaterUI
import Foundation
import MapKit

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - Map View Component

private struct WuiNativeMapAnnotation {
  let coordinate: CLLocationCoordinate2D
  let title: String
  let subtitle: String?

  init(consuming annotation: CWaterUI.WuiAnnotation) {
    coordinate = CLLocationCoordinate2D(
      latitude: annotation.coordinate.latitude,
      longitude: annotation.coordinate.longitude
    )
    title = WuiStr(annotation.title).toString()
    let subtitle = WuiStr(annotation.subtitle).toString()
    self.subtitle = subtitle.isEmpty ? nil : subtitle
  }
}

private func consumeMapAnnotations(
  _ array: CWaterUI.WuiArray_WuiAnnotation
) -> [WuiNativeMapAnnotation] {
  let raw = unsafeBitCast(array, to: CWaterUI.WuiArray.self)
  return WuiArray<CWaterUI.WuiAnnotation>(c: raw).map(
    WuiNativeMapAnnotation.init(consuming:)
  )
}

@MainActor
private func makeMapAnnotationsWatcher(
  _ callback: @escaping ([WuiNativeMapAnnotation], WuiWatcherMetadata) -> Void
) -> OpaquePointer {
  let data = wrap(callback)
  let call:
    @convention(c) (
      UnsafeMutableRawPointer?,
      CWaterUI.WuiArray_WuiAnnotation,
      OpaquePointer?
    ) -> Void = { data, value, metadata in
      precondition(Thread.isMainThread, "Map annotations left their owning UI thread")
      callWrapper(data, consumeMapAnnotations(value), metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, [WuiNativeMapAnnotation].self)
  }
  guard let watcher = waterui_new_watcher_annotations(data, call, drop) else {
    fatalError("Failed to create the Map annotations watcher")
  }
  return watcher
}

/// A location the application supplied, drawn as WaterUI's own marker.
///
/// MapKit's `showsUserLocation` tracks CoreLocation, which is a second source
/// of truth. When the application drives the location itself, the map must show
/// that reading instead so both agree.
private struct WuiSuppliedLocation {
  let coordinate: CLLocationCoordinate2D
  let horizontalAccuracy: CLLocationDistance?

  init?(_ location: CWaterUI.WuiLocation) {
    guard location.has_location else {
      return nil
    }
    coordinate = CLLocationCoordinate2D(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude
    )
    horizontalAccuracy = location.has_horizontal_accuracy ? location.horizontal_accuracy : nil
  }
}

@MainActor
private func makeUserLocationComputed(
  _ pointer: OpaquePointer
) -> WuiComputed<WuiSuppliedLocation?> {
  WuiComputed<WuiSuppliedLocation?>(
    inner: pointer,
    read: { pointer in WuiSuppliedLocation(waterui_read_computed_user_location(pointer)) },
    watch: { pointer, callback in
      let watcher = makeUserLocationWatcher(callback)
      guard let guardPointer = waterui_watch_computed_user_location(pointer, watcher) else {
        fatalError("Failed to watch the Map user location signal")
      }
      return WatcherGuard(guardPointer)
    },
    drop: waterui_drop_computed_user_location
  )
}

@MainActor
private func makeUserLocationWatcher(
  _ callback: @escaping (WuiSuppliedLocation?, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
  let data = wrap(callback)
  let call:
    @convention(c) (
      UnsafeMutableRawPointer?,
      CWaterUI.WuiLocation,
      OpaquePointer?
    ) -> Void = { data, value, metadata in
      precondition(Thread.isMainThread, "Map user location left its owning UI thread")
      callWrapper(data, WuiSuppliedLocation(value), metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiSuppliedLocation?.self)
  }
  guard let watcher = waterui_new_watcher_user_location(data, call, drop) else {
    fatalError("Failed to create the Map user location watcher")
  }
  return watcher
}

@MainActor
private func makeMapRegionComputed(_ pointer: OpaquePointer) -> WuiComputed<WuiRegion> {
  WuiComputed<WuiRegion>(
    inner: pointer,
    read: waterui_read_computed_region,
    watch: { pointer, callback in
      let watcher = makeRegionWatcher(callback)
      guard let guardPointer = waterui_watch_computed_region(pointer, watcher) else {
        fatalError("Failed to watch the Map region signal")
      }
      return WatcherGuard(guardPointer)
    },
    drop: waterui_drop_computed_region
  )
}

@MainActor
private func makeMapAnnotationsComputed(
  _ pointer: OpaquePointer
) -> WuiComputed<[WuiNativeMapAnnotation]> {
  WuiComputed<[WuiNativeMapAnnotation]>(
    inner: pointer,
    read: { pointer in
      consumeMapAnnotations(waterui_read_computed_annotations(pointer))
    },
    watch: { pointer, callback in
      let watcher = makeMapAnnotationsWatcher(callback)
      guard let guardPointer = waterui_watch_computed_annotations(pointer, watcher) else {
        fatalError("Failed to watch the Map annotations signal")
      }
      return WatcherGuard(guardPointer)
    },
    drop: waterui_drop_computed_annotations
  )
}

/// Native component that renders a MapView in the view hierarchy.
@MainActor
final class WuiMapViewComponent: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_map_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both
  private let mapView: MKMapView
  private var regionObservation: WuiComputedObservation<WuiRegion>?
  private var annotationsObservation: WuiComputedObservation<[WuiNativeMapAnnotation]>?
  private var renderedAnnotations: [MKPointAnnotation] = []
  private var userLocationObservation: WuiComputedObservation<WuiSuppliedLocation?>?
  private var suppliedLocationOverlay: MKCircle?
  private var suppliedLocationMarker: MKPointAnnotation?

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    // Get the WuiMap config (returns by value)
    let config = waterui_force_as_map(anyview)
    self.init(config: config)
  }

  init(config: WuiMap) {
    self.mapView = MKMapView(frame: .zero)
    super.init(frame: .zero)

    // Set initial configuration
    #if canImport(UIKit)
      mapView.isUserInteractionEnabled = config.is_interactive
      mapView.showsScale = config.shows_scale
    #endif
    mapView.showsCompass = config.shows_compass
    mapView.showsUserLocation = config.shows_user_location

    // Set map style
    switch config.style {
    case WuiMapStyle_Standard:
      mapView.mapType = .standard
    case WuiMapStyle_Satellite:
      mapView.mapType = .satellite
    case WuiMapStyle_Hybrid:
      mapView.mapType = .hybrid
    default:
      fatalError("Unsupported WaterUI map style: \(config.style.rawValue)")
    }

    guard let regionPointer = config.region else {
      fatalError("Map requires a region signal")
    }
    let regionObservation = WuiComputedObservation(makeMapRegionComputed(regionPointer)) {
      [weak self] region, metadata in
      self?.updateRegion(region, animated: metadata.animation != nil)
    }
    self.regionObservation = regionObservation
    updateRegion(regionObservation.value, animated: false)

    guard let annotationsPointer = config.annotations else {
      fatalError("Map requires an annotations signal")
    }
    let annotationsObservation = WuiComputedObservation(
      makeMapAnnotationsComputed(annotationsPointer)
    ) { [weak self] annotations, _ in
      self?.reconcileAnnotations(annotations)
    }
    self.annotationsObservation = annotationsObservation
    reconcileAnnotations(annotationsObservation.value)

    // An application-supplied location replaces CoreLocation tracking, so the
    // map never shows two disagreeing positions.
    if let locationPointer = config.user_location {
      mapView.showsUserLocation = false
      let observation = WuiComputedObservation(makeUserLocationComputed(locationPointer)) {
        [weak self] location, _ in
        self?.applySuppliedLocation(location)
      }
      userLocationObservation = observation
      applySuppliedLocation(observation.value)
    }

    // Add map view as subview using manual frame layout
    mapView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(mapView)

  }

  private func applySuppliedLocation(_ location: WuiSuppliedLocation?) {
    if let overlay = suppliedLocationOverlay {
      mapView.removeOverlay(overlay)
      suppliedLocationOverlay = nil
    }
    if let marker = suppliedLocationMarker {
      mapView.removeAnnotation(marker)
      suppliedLocationMarker = nil
    }
    guard let location else {
      return
    }
    let marker = MKPointAnnotation()
    marker.coordinate = location.coordinate
    mapView.addAnnotation(marker)
    suppliedLocationMarker = marker
    if let accuracy = location.horizontalAccuracy, accuracy > 0 {
      let overlay = MKCircle(center: location.coordinate, radius: accuracy)
      mapView.addOverlay(overlay)
      suppliedLocationOverlay = overlay
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func updateRegion(_ wuiRegion: WuiRegion, animated: Bool) {
    let center = CLLocationCoordinate2D(
      latitude: wuiRegion.center.latitude,
      longitude: wuiRegion.center.longitude
    )
    let span = MKCoordinateSpan(
      latitudeDelta: wuiRegion.latitude_delta,
      longitudeDelta: wuiRegion.longitude_delta
    )
    let region = MKCoordinateRegion(center: center, span: span)
    mapView.setRegion(region, animated: animated)
  }

  private func reconcileAnnotations(_ values: [WuiNativeMapAnnotation]) {
    let reusedCount = min(renderedAnnotations.count, values.count)
    for index in 0..<reusedCount {
      apply(values[index], to: renderedAnnotations[index])
    }

    if renderedAnnotations.count > values.count {
      let removed = Array(renderedAnnotations[values.count...])
      mapView.removeAnnotations(removed)
      renderedAnnotations.removeLast(removed.count)
    } else if values.count > renderedAnnotations.count {
      let added = values[renderedAnnotations.count...].map { value in
        let annotation = MKPointAnnotation()
        apply(value, to: annotation)
        return annotation
      }
      renderedAnnotations.append(contentsOf: added)
      mapView.addAnnotations(added)
    }
  }

  private func apply(_ value: WuiNativeMapAnnotation, to annotation: MKPointAnnotation) {
    annotation.coordinate = value.coordinate
    annotation.title = value.title
    annotation.subtitle = value.subtitle
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    // MapView is greedy - it takes all available space
    let width = proposal.width.map { CGFloat($0) } ?? 320
    let height = proposal.height.map { CGFloat($0) } ?? 480
    return CGSize(width: width, height: height)
  }

  // MARK: - Layout

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      mapView.frame = bounds
    }
  #elseif canImport(AppKit)
    override func layout() {
      super.layout()
      mapView.frame = bounds
    }

    nonisolated override var isFlipped: Bool { true }
  #endif
}

#endif
