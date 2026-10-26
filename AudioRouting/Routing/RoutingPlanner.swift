import CoreAudio
import Foundation

/// One app's audio sent to one output device.
struct DesiredRoute: Hashable, Sendable {
    let bundleID: String
    let deviceUID: String
    /// Core Audio process objects of the app, sorted. A change here means the tap must be rebuilt.
    let processObjectIDs: [AudioObjectID]
}

struct RoutingPlan: Equatable, Sendable {
    var create: [DesiredRoute] = []
    var destroy: [DesiredRoute] = []

    var isEmpty: Bool { create.isEmpty && destroy.isEmpty }
}

/// Pure routing computation, kept free of Core Audio so it can be unit-tested directly.
enum RoutingPlanner {
    /// Routes that should exist now. An app is routed only when it is running, its saved device is
    /// connected, and that device is not already the system default (then no tap is needed).
    static func desiredRoutes(
        settings: AppRoutingSettings,
        apps: [AudioApp],
        connectedDeviceUIDs: Set<String>,
        defaultOutputUID: String?
    ) -> [String: DesiredRoute] {
        var result: [String: DesiredRoute] = [:]
        for app in apps {
            guard let deviceUID = settings.routes[app.bundleID],
                  connectedDeviceUIDs.contains(deviceUID),
                  deviceUID != defaultOutputUID,
                  !app.processes.isEmpty
            else { continue }
            result[app.bundleID] = DesiredRoute(
                bundleID: app.bundleID,
                deviceUID: deviceUID,
                processObjectIDs: app.processes.map(\.objectID).sorted()
            )
        }
        return result
    }

    /// The difference between what is running and what should be. A route whose device or
    /// process set changed is destroyed and created again.
    static func plan(desired: [String: DesiredRoute], active: [String: DesiredRoute]) -> RoutingPlan {
        var plan = RoutingPlan()
        for (bundleID, route) in active where desired[bundleID] != route {
            plan.destroy.append(route)
        }
        for (bundleID, route) in desired where active[bundleID] != route {
            plan.create.append(route)
        }
        plan.destroy.sort { $0.bundleID < $1.bundleID }
        plan.create.sort { $0.bundleID < $1.bundleID }
        return plan
    }
}
