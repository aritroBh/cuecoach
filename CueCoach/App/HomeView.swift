import SwiftUI

/// Home: one big Play (camera) entry.
struct HomeView: View {
    @State private var playing = false

    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.059, blue: 0.055).ignoresSafeArea()
            VStack(spacing: 48) {
                Spacer()
                Image(systemName: "circle.circle")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("home.logo")
                Spacer()
                Button { playing = true } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 128, height: 128)
                        .background(Circle().fill(Color(red: 0.29, green: 0.87, blue: 0.5)))
                }
                .accessibilityIdentifier("home.play")
                .accessibilityLabel("Play")
                .padding(.bottom, 56)
            }
        }
        .fullScreenCover(isPresented: $playing) { LiveScreen() }
    }
}
