#if DEBUG
import SwiftUI

/// `-pokiScreen bear`: the three-dimensional bear large, in the outfit it wears, waving every few
/// seconds, so each piece can be checked through the wave. `-pokiBearFrame N` holds one frame.
struct BearStage: View {
    @State private var pokes = 0

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ModelBear(act: .ready, side: 340, pokes: pokes) { Color.clear }
                .frame(width: 340, height: 340)
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                pokes += 1
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}
#endif
