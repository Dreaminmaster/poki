import SwiftUI

struct UpdateFinishView: View {
    let message: String
    let needsReopen: Bool

    var body: some View {
        VStack(spacing: 24) {
            if needsReopen {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(needsReopen ? "Reopen Poki" : "Finishing the Update")
                .font(.title2.bold())
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}
