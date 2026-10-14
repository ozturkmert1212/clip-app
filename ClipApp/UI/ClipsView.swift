import SwiftUI

struct ClipsView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No clips yet")
                .font(.title3)
            Text("Saved clips appear here. Press the clip shortcut or use the save button to keep the last seconds.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding()
    }
}
