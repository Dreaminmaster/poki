import SwiftUI


/// The two speed-ups being tried (General › Testing Options), both on unless turned off there.
enum SpeedOptions {
    static let appNamesKey = "testing.appNames"
    static let quickReadKey = "testing.quickRead"
    static var appNames: Bool { UserDefaults.standard.object(forKey: appNamesKey) as? Bool ?? true }
    static var quickRead: Bool { UserDefaults.standard.object(forKey: quickReadKey) as? Bool ?? true }
}

/// General › Testing Options: the switches for the two speed-ups.
struct SpeedTestingSection: View {
    @AppStorage(SpeedOptions.appNamesKey) private var appNames = true
    @AppStorage(SpeedOptions.quickReadKey) private var quickRead = true
    var body: some View {
        Section {
            Toggle("Apps by Name", isOn: $appNames)
            Toggle("Read When the Screen Settles", isOn: $quickRead)
        } header: {
            Text("Speed")
        } footer: {
            Group {
                Text("On by default. Apps by Name lets an agent open an app by its name and keep it as the app it works in. Read When the Screen Settles reads the screen as soon as it has changed and holds still after an app opens, a swipe or a button, in place of a fixed pause. Changes count from the next step.")
            }
            .settingsFooter()
        }
    }
}
