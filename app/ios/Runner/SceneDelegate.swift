import Flutter
import QuartzCore
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    DispatchQueue.main.async { [weak self] in
      self?.enableExtendedDynamicRangeOnFlutterLayer()
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    enableExtendedDynamicRangeOnFlutterLayer()
  }

  private func enableExtendedDynamicRangeOnFlutterLayer() {
    guard let layer = flutterRootLayer else {
      return
    }

    if #available(iOS 26.0, *) {
      layer.preferredDynamicRange = .high
      layer.contentsHeadroom = max(layer.contentsHeadroom, 3)
    } else if #available(iOS 17.0, *) {
      layer.wantsExtendedDynamicRangeContent = true
    } else if #available(iOS 16.0, *), let metalLayer = layer as? CAMetalLayer {
      metalLayer.wantsExtendedDynamicRangeContent = true
    }
  }

  private var flutterRootLayer: CALayer? {
    if let layer = window?.rootViewController?.view.layer {
      return layer
    }

    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }?
      .rootViewController?
      .view
      .layer
  }
}
