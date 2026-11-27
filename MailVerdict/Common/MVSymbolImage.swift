import MailVerdictKit
import SwiftUI
import UIKit

/// Draws an `MVSymbols` name: an SF Symbol, or one of the custom symbols in the asset catalog
/// (`MVSymbols.custom`), which `systemName:` cannot find.
extension Image {
    init(mvSymbol name: String) {
        if MVSymbols.custom.contains(name) {
            self.init(name)
        } else {
            self.init(systemName: name)
        }
    }
}

extension UIImage {
    static func mvSymbol(_ name: String) -> UIImage? {
        MVSymbols.custom.contains(name) ? UIImage(named: name) : UIImage(systemName: name)
    }
}

/// `Label(_:image:)` rather than a custom icon view: a `Menu` renders only the two built-in forms.
extension Label where Title == Text, Icon == Image {
    init(_ title: String, mvSymbol name: String) {
        if MVSymbols.custom.contains(name) {
            self.init(title, image: name)
        } else {
            self.init(title, systemImage: name)
        }
    }
}
