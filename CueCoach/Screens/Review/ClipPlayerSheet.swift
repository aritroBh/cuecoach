import AVFoundation
import AVKit
import SwiftUI

struct PresentedClipItem: Identifiable {
    let id: UUID
    let url: URL
    let label: String
}

/// Full-screen / sheet in-app video player for Shot of the Game clips (SPEC §9, D55).
struct ClipPlayerSheet: View {
    let item: PresentedClipItem
    let onClose: () -> Void
    @State private var player: AVPlayer

    init(item: PresentedClipItem, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        self._player = State(initialValue: AVPlayer(url: item.url))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AXLive.stage.ignoresSafeArea()
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("review.clip.player")
            }
            .navigationTitle(item.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        player.pause()
                        onClose()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("review.clip.done")
                }
            }
        }
        .tint(AX.accentText)
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}
