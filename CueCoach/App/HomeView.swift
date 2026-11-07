import SwiftUI

/// Placeholder home; real design lands with the virtual-table design pass.
struct HomeView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(systemName: "circle.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white)
                .accessibilityIdentifier("home.logo")
        }
    }
}
