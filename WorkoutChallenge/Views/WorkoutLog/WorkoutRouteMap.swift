//
//  WorkoutRouteMap.swift
//  WorkoutChallenge
//
//  Maps the GPS polyline recorded during an outdoor workout. Opted into
//  only when `WorkoutDetails.routeLocations` is non-empty — walking a
//  cycling workout or a manual entry doesn't get a map.
//
//  Uses iOS 17's content-builder Map API so we can drop a MapPolyline
//  stroke directly without an MKMapViewRepresentable bridge.
//

import SwiftUI
import MapKit
import CoreLocation

struct WorkoutRouteMap: View {
    let locations: [CLLocation]

    var body: some View {
        if !locations.isEmpty {
            AppSection(title: "Route") {
                VStack(alignment: .leading, spacing: Space.x3) {
                    Map(initialPosition: .region(region)) {
                        MapPolyline(coordinates: locations.map(\.coordinate))
                            .stroke(
                                Color.accentInk,
                                style: StrokeStyle(
                                    lineWidth: 4,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                        if let start = locations.first {
                            Marker("Start", systemImage: "flag.fill",
                                   coordinate: start.coordinate)
                                .tint(.accentVolt)
                        }
                        if locations.count > 1, let end = locations.last {
                            Marker("End", systemImage: "flag.checkered",
                                   coordinate: end.coordinate)
                                .tint(.accentInk)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card - 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card - 6)
                            .stroke(Color.appBorder, lineWidth: 1)
                    )

                    footnote
                }
            }
        }
    }

    /// Pad the bounding box by 30% so the polyline doesn't touch the edge
    /// of the map tile, and floor the span so a near-stationary workout
    /// still renders at a usable zoom level (~100m).
    private var region: MKCoordinateRegion {
        let lats = locations.map(\.coordinate.latitude)
        let lons = locations.map(\.coordinate.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.002, (maxLat - minLat) * 1.3),
            longitudeDelta: max(0.002, (maxLon - minLon) * 1.3)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private var footnote: some View {
        let points = locations.count
        let horizontalAccuracy = locations
            .map(\.horizontalAccuracy)
            .filter { $0 > 0 }
        let avgAcc = horizontalAccuracy.isEmpty
            ? nil
            : horizontalAccuracy.reduce(0, +) / Double(horizontalAccuracy.count)

        return HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("\(points) GPS points")
            if let avgAcc {
                Text("·")
                Text("~±\(Int(avgAcc.rounded()))m accuracy")
            }
        }
        .font(AppFont.mono(10))
        .foregroundStyle(Color.textTertiary)
    }
}
