The implementation plan is solid and addresses a clear UX gap, but it lacks details on how the SwiftUI view will reactively update when background sync states change or when relative time becomes stale.

### 🟡 Medium

**Missing UI reactivity for background sync updates**
Location: Architecture
Making `SyncScheduler.lastCycleAt` `private(set)` is insufficient for SwiftUI to detect changes. If `SyncScheduler` is not an `ObservableObject` (or `@Observable`) publishing this property on the MainActor, the settings UI will not refresh when a sync completes in the background.
Fix: Ensure `SyncScheduler` conforms to `ObservableObject` and marks `lastCycleAt` with `@Published` (dispatched on the MainActor), or broadcast a notification that the UI listens to.

### 🟢 Low

**Stale relative time caption**
Location: Architecture: MainView.SettingsPage
Using `RelativeDateTimeFormatter` directly in the view will result in a static string that becomes stale (e.g., permanently showing 'Just now') until the user navigates away and back.
Fix: Use SwiftUI's native relative date formatting, such as `Text(lastCycleAt, style: .relative)`, which automatically updates the relative time on screen without manual timers.

**Implicit side-effect on toggle state change**
Location: Requirements: Functional
Binding the toggle directly to `Settings.syncEnabled` will not automatically trigger `SyncScheduler.triggerUnconditional` unless the state change is explicitly intercepted.
Fix: Use SwiftUI's `.onChange(of: syncEnabled)` modifier or a custom `Binding` wrapper in the view to trigger the unconditional sync when the toggle transitions from false to true.
