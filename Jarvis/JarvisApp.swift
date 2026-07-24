import SwiftUI

@main
struct JarvisApp: App {
    @State private var session = AssistantSession()

    var body: some Scene {
        WindowGroup {
            ConversationView()
                .environment(session)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
