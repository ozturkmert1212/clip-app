import SwiftUI

/// Root of every hosted SwiftUI tree: puts the chosen language into the
/// environment, which is what `Text` and the other literal-based views
/// resolve against, and re-renders when it changes. It also sets the tint,
/// so controls are indigo whatever accent color the system is set to.
struct LanguageRoot<Content: View>: View {
    @ObservedObject var settings: SettingsStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.locale, settings.language.locale)
            .tint(Brand.accent)
    }
}
