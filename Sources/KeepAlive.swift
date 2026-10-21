import AVFoundation
import CoreLocation
import Foundation

/// iOS freezes an app a few seconds after it leaves the screen, unless it has a reason to run
/// (audio playing, location in use). The glasses app is in front while this one has to keep working,
/// so it gives itself one: either silent audio or a slow location session (the location trick is
/// what kept a server alive in the earlier iSH test). The location is never read.
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    private let engine = AVAudioEngine()
    private var audioRunning = false
    private var location: CLLocationManager?

    func setAudio(_ on: Bool) {
        if on, !audioRunning {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                let silence = AVAudioSourceNode { _, _, _, audioBufferList in
                    for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                    return noErr
                }
                engine.attach(silence)
                engine.connect(silence, to: engine.mainMixerNode, format: nil)
                try engine.start()
                audioRunning = true
                appLog("keep-alive: silent audio running")
            } catch {
                appLog("keep-alive audio failed: \(error)")
            }
        } else if !on, audioRunning {
            engine.stop()
            audioRunning = false
            appLog("keep-alive: silent audio stopped")
        }
    }

    func setLocation(_ on: Bool) {
        if on, location == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            manager.distanceFilter = kCLDistanceFilterNone
            manager.pausesLocationUpdatesAutomatically = false
            manager.allowsBackgroundLocationUpdates = true
            manager.requestAlwaysAuthorization()
            manager.startUpdatingLocation()
            location = manager
            appLog("keep-alive: location session started")
        } else if !on, let manager = location {
            manager.stopUpdatingLocation()
            location = nil
            appLog("keep-alive: location session stopped")
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLog("location: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        appLog("location permission: \(manager.authorizationStatus.rawValue)")
    }
}
