import Foundation
import UIKit
import Photos

/// How a screenshot reaches the app.
///
/// On iOS nothing lets an app read another app's screen, so the screen arrives as a screenshot the
/// user took. The cheapest gesture is: screenshot the chat, come back, tap once — so the app looks
/// for the newest screenshot in the library rather than making the user pick from a grid.
public enum ScreenshotIntake {

    public static func ensureAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized, .limited: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        @unknown default:
            return false
        }
    }

    /// Newest screenshot in the library, at native resolution (never resampled: downscaling costs
    /// ~11% character accuracy and invents bubbles out of avatar artwork).
    public static func newestScreenshot(newerThan date: Date? = nil) async -> UIImage? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 12
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard assets.count > 0 else { return nil }

        var candidates: [PHAsset] = []
        assets.enumerateObjects { asset, _, stop in
            // `.photoScreenshot` is the system's own classification; no guessing from size or name.
            guard asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            if let date, let created = asset.creationDate, created <= date { return }
            candidates.append(asset)
            if candidates.count >= 3 { stop.pointee = true }
        }
        guard let asset = candidates.first else { return nil }
        return await image(for: asset)
    }

    public static func image(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none            // native pixels, no downscale
            options.version = .current
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded { return }        // wait for the full-quality pass
                    continuation.resume(returning: image)
                }
        }
    }

    /// Screenshots the user already took, for a gallery picker.
    public static func recentScreenshots(limit: Int = 20) async -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit * 3
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var out: [PHAsset] = []
        assets.enumerateObjects { asset, _, stop in
            guard asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            out.append(asset)
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }
}