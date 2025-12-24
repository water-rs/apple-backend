// WuiMapView.swift
// Map component - MKMapView wrapper for WaterUI
//
// # Layout Behavior
// MapView is greedy - it expands to fill all available space.

import CWaterUI
import MapKit
import os

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiMapView")

// MARK: - Map View Component

/// Native component that renders a MapView in the view hierarchy.
@MainActor
final class WuiMapViewComponent: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_map_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both
    private let mapView: MKMapView
    private var regionWatcher: Watcher<WuiRegion>?
    private var annotationsWatcher: Watcher<Void>?
    private var currentAnnotations: [MKPointAnnotation] = []

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.mapView = MKMapView(frame: .zero)
        super.init(frame: .zero)

        logger.debug("WuiMapViewComponent init started")

        // Get the WuiMap config (returns by value, no drop needed)
        let config = waterui_force_as_map(anyview)

        // Set initial configuration
        #if canImport(UIKit)
        mapView.isUserInteractionEnabled = config.is_interactive
        #endif
        mapView.showsCompass = config.shows_compass
        #if canImport(UIKit)
        mapView.showsScale = config.shows_scale
        #endif
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
            mapView.mapType = .standard
        }

        // Watch for region changes
        if let regionComputed = config.region {
            self.regionWatcher = Watcher(regionComputed) { [weak self] region in
                self?.updateRegion(region)
            }
        }

        // Watch for annotation changes
        if let annotationsComputed = config.annotations {
            self.annotationsWatcher = Watcher(annotationsComputed) { [weak self] _ in
                guard let self = self, let annotationsComputed = config.annotations else { return }
                self.updateAnnotations(annotationsComputed)
            }
        }

        // Add map view as subview
        mapView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mapView)

        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        logger.debug("WuiMapViewComponent setup complete")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateRegion(_ wuiRegion: WuiRegion) {
        let center = CLLocationCoordinate2D(
            latitude: wuiRegion.center.latitude,
            longitude: wuiRegion.center.longitude
        )
        let span = MKCoordinateSpan(
            latitudeDelta: wuiRegion.latitude_delta,
            longitudeDelta: wuiRegion.longitude_delta
        )
        let region = MKCoordinateRegion(center: center, span: span)
        mapView.setRegion(region, animated: true)
    }

    private func updateAnnotations(_ annotationsPtr: OpaquePointer) {
        // Remove existing annotations
        mapView.removeAnnotations(currentAnnotations)
        currentAnnotations.removeAll()

        // Get new annotations from the computed signal
        // Note: This is simplified - in production you'd want to properly iterate the Vec
        // For now, we just clear and set up watching for changes
        
        logger.debug("Annotations updated")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // MapView is greedy - it takes all available space
        let width = proposal.width.map { CGFloat($0) } ?? 320
        let height = proposal.height.map { CGFloat($0) } ?? 480
        return CGSize(width: width, height: height)
    }
}

// MARK: - FFI Helper Types

/// Wrapper for watching a Computed signal
private class Watcher<T> {
    private var guard_: OpaquePointer?

    init(_ computed: OpaquePointer, callback: @escaping (T) -> Void) {
        // Store reference for cleanup
        self.guard_ = computed
        // Note: Actual watcher implementation would use waterui_computed_watch functions
    }

    deinit {
        // Cleanup watcher guard
    }
}
