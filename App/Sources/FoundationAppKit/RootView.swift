import SwiftUI
import FoundationCore

public struct RootView: View {
    @State private var status: StatusResponse?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ModelBanner(status: status)
            Divider()
            TabView {
                ChatView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                SampleView()
                    .tabItem { Label("Image", systemImage: "photo") }
            }
        }
        .task { status = await InferenceService().status() }
    }
}
