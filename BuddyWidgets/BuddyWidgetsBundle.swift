import SwiftUI
import WidgetKit

@main
struct BuddyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BuddyHomeWidget()
        BuddyLockScreenWidget()
        #if canImport(ActivityKit)
        WorkoutLiveActivity()
        #endif
    }
}
