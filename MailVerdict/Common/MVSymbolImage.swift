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

extension Label where Title == Text, Icon == Image {
    init(_ title: String, mvSymbol name: String) {
        self.init {
            Text(title)
        } icon: {
            Image(mvSymbol: name)
        }
    }
}
