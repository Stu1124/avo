import AppKit
import CoreLocation
import Foundation

/// Where the user is: CoreLocation first, a coarse IP guess as fallback.
enum LocationTools {
    static let group = "Apps"

    /// Registered by way of `TextTools.all()`; the flag makes a second call (if anyone wires
    /// LocationTools.all() directly) a no-op so the registry never lists these tools twice.
    private static let lock = NSLock()
    private static var handedOut = false

    static func all() -> [Tool] {
        lock.lock()
        defer { lock.unlock() }
        if handedOut { return [] }
        handedOut = true
        return [CurrentLocationTool(), OpenLocationSettingsTool()]
    }
}

// MARK: - get_current_location

private struct CurrentLocationTool: Tool {
    let name = "get_current_location"
    let description = """
    Reads where this Mac is — latitude and longitude — for the user. Two shapes of request fit. Where they want to know \
    their own whereabouts ('where am I', 'what street is this', 'which neighborhood am I in'), ANSWER straight from what \
    comes back and do NOT go searching for places. Where instead they want something found near them and have named no place, \
    fetch the position FIRST and feed those coordinates into the search that follows. What returns is lat, lng, accuracy_m \
    and source. A source of 'device' is a genuine OS fix through CoreLocation; 'ip' is a rough network lookup that can be WRONG, \
    off by a city or a whole country behind a VPN, so an 'ip' answer must NEVER be stated as the user's settled position \
    — say roughly where it points, ask them to confirm, and follow its `note`. On ok:false, do as the `guidance` says.
    """
    let params: [ToolParam] = []
    let statusLabel = "Locating"
    let statusIcon = "location.fill"
    let group = LocationTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        // Denied Location falls through to the coarse IP guess rather than failing the turn, so the
        // gate's card explains the missing permission while the model still gets an approximate answer.
        let allowed = await PermissionGate.ensure(.location)
        guard allowed else { return await ipFallback(reason: "Location Services permission is off for Avo.") }
        let fetcher = LocationFetcher()
        switch await fetcher.fetch(timeout: 4) {
        case .location(let loc):
            var json: [String: Any] = [
                "ok": true,
                "lat": round(loc.coordinate.latitude * 1_000_000) / 1_000_000,
                "lng": round(loc.coordinate.longitude * 1_000_000) / 1_000_000,
                "source": "device"
            ]
            if loc.horizontalAccuracy >= 0 { json["accuracy_m"] = Int(loc.horizontalAccuracy.rounded()) }
            return .ok(json)
        case .denied:
            return await ipFallback(reason: "Location Services permission is off for Avo.")
        case .timeout:
            return await ipFallback(reason: "The device did not return a fix within 4 seconds.")
        case .failed(let message):
            return await ipFallback(reason: "CoreLocation failed: \(message)")
        }
    }

    /// Coarse network lookup. Always flagged so the model never states it as fact.
    private func ipFallback(reason: String) async -> ToolResult {
        guard let url = URL(string: "https://ipapi.co/json/") else {
            return .fail("Could not get the user's location. \(reason)", guidance: "Tell the user location is unavailable and offer open_location_settings.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("Avo/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lat = (obj["latitude"] as? NSNumber)?.doubleValue,
                  let lng = (obj["longitude"] as? NSNumber)?.doubleValue else {
                return .fail("Could not get the user's location. \(reason)", guidance: "Tell the user Avo could not read their location and offer to open Location Services settings (open_location_settings).")
            }
            var json: [String: Any] = [
                "ok": true, "lat": lat, "lng": lng, "source": "ip", "accuracy_m": 25000,
                "note": "Coarse network-based guess, NOT a device fix (\(reason)) — it can be wrong, a different city or country on a VPN. Never present it as the user's confirmed location: say it looks approximately like this place, ask them to confirm, and offer open_location_settings to turn on precise location."
            ]
            if let city = obj["city"] as? String { json["city"] = city }
            if let region = obj["region"] as? String { json["region"] = region }
            if let country = obj["country_name"] as? String { json["country"] = country }
            return .ok(json)
        } catch {
            return .fail("Could not get the user's location. \(reason)", guidance: "Tell the user location is unavailable, and offer open_location_settings so they can turn on Location Services for Avo.")
        }
    }
}

// MARK: - open_location_settings

private struct OpenLocationSettingsTool: Tool {
    let name = "open_location_settings"
    let description = """
    Brings up the macOS pane where Location Services can be handed to Avo, which is what makes a precise fix possible. It \
    applies after get_current_location came back short of permission — ok:false, or an 'ip' source whose note blames the \
    permission — and ONLY once the user actually wants that put right: offer it first, then call it when they agree or ask \
    for it themselves. It lands on Privacy & Security, then Location Services, where two switches matter: the master Location \
    Services toggle at the top has to be ON, and Avo has to be turned on in the app list below it. Say BOTH once the pane \
    is up — one without the other still leaves Avo without a fix.
    """
    let params: [ToolParam] = []
    let statusLabel = "Opening settings"
    let statusIcon = "gearshape"
    let group = LocationTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        guard let url = URL(string: urlString) else { return .fail("Could not build the settings URL") }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            return .fail("Could not open System Settings", guidance: "Ask the user to open System Settings themselves, go to Privacy & Security > Location Services, turn Location Services on, and then switch Avo on in the app list below.")
        }
        return .ok(["ok": true, "opened": "Privacy & Security > Location Services",
                    "guidance": "Tell the user to turn Location Services itself on at the top of the pane and then switch Avo on in the app list below — both are needed — and to ask again once done."])
    }
}

// MARK: - one-shot CoreLocation

/// Single-use CoreLocation request with a hard timeout; resumes its continuation exactly once.
private final class LocationFetcher: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    enum Outcome {
        case location(CLLocation)
        case denied
        case timeout
        case failed(String)
    }

    private var manager: CLLocationManager?
    private let lock = NSLock()
    private var cont: CheckedContinuation<Outcome, Never>?

    func fetch(timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
            lock.lock(); cont = c; lock.unlock()
            DispatchQueue.main.async {
                let m = CLLocationManager()
                m.delegate = self
                m.desiredAccuracy = kCLLocationAccuracyHundredMeters
                self.manager = m
                switch m.authorizationStatus {
                case .notDetermined: m.requestWhenInUseAuthorization()
                case .denied, .restricted: self.finish(.denied)
                default: m.requestLocation()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { self.finish(.timeout) }
        }
    }

    private func finish(_ outcome: Outcome) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        guard let c else { return }
        DispatchQueue.main.async {
            self.manager?.stopUpdatingLocation()
            self.manager?.delegate = nil
            self.manager = nil
        }
        c.resume(returning: outcome)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let l = locations.last { finish(.location(l)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failed(error.localizedDescription))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(.denied)
        default: manager.requestLocation()
        }
    }
}
