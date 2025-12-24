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
    private var regionWatcherGuard: WatcherGuard?

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        // Get the WuiMap config (returns by value)
        let config = waterui_force_as_map(anyview)
        self.init(config: config)
    }
    
    init(config: WuiMap) {
        self.mapView = MKMapView(frame: .zero)
        super.init(frame: .zero)

        logger.debug("WuiMapViewComponent init started")

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
            mapView.mapType = .standard
        }

        // Read initial region and set it
        if let regionComputed = config.region {
            let initialRegion = waterui_read_computed_region(regionComputed)
            updateRegion(initialRegion, animated: false)
            
            // Watch for region changes
            let watcher = makeRegionWatcher { [weak self] region, metadata in
                let animated = metadata.animation != nil
                self?.updateRegion(region, animated: animated)
            }
            if let guard_ = waterui_watch_computed_region(regionComputed, watcher) {
                self.regionWatcherGuard = WatcherGuard(guard_)
            }
        }

        // Add map view as subview using manual frame layout
        mapView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(mapView)

        logger.debug("WuiMapViewComponent setup complete")
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
    
    override var isFlipped: Bool { true }
    #endif
}
