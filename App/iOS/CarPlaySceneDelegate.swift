import Foundation
import SwiftUI
import CarPlay

// MARK: - CarPlay Scene Delegate (Stubbed for Future Implementation)

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        
        // Create a basic template for CarPlay
        let gridTemplate = CPGridTemplate(title: "SignalHive", gridButtons: [])
        interfaceController.setRootTemplate(gridTemplate, animated: true)
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }
}

// MARK: - CarPlay Scene Delegate (macOS Stub)

#if targetEnvironment(macCatalyst) || os(macOS)
// On macOS, CarPlay is not available - this is a no-op stub
class CarPlaySceneDelegateStub: NSObject {
    static func register() {
        // CarPlay not available on macOS
    }
}
#endif