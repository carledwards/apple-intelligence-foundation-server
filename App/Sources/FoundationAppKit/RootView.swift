import SwiftUI

public struct RootView: View {
    public init() {}

    public var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            SampleView()
                .tabItem { Label("Image", systemImage: "photo") }
            PhotoBatchView()
                .tabItem { Label("Photos", systemImage: "photo.stack") }
        }
    }
}
