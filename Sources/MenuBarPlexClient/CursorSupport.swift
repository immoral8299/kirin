import AppKit
import SwiftUI

private struct CursorModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.onHover { isHovering in
            guard isHovering else {
                NSCursor.pop()
                return
            }

            (isEnabled ? NSCursor.pointingHand : NSCursor.operationNotAllowed).push()
        }
    }
}

extension View {
    func interactiveCursor(disabled: Bool = false) -> some View {
        modifier(CursorModifier(isEnabled: !disabled))
    }
}
