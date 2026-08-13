import SwiftUI

// Xcode canvas coverage for every phone screen, in both the empty and populated
// states. Split out of DemoData so the generator itself stays free of SwiftUI —
// that keeps it type-checkable and runnable off-device, which is how the example
// session's numbers get sanity-checked without a simulator.

// MARK: - Previews

#Preview("Today — empty") {
    TodayView(c: PhoneController.preview(swings: []))
}

#Preview("Today — after a session") {
    TodayView(c: PhoneController.preview(swings: DemoData.history(sessions: 4, perSession: 20)))
}

#Preview("Form — populated") {
    FormView(c: PhoneController.preview(swings: DemoData.history()))
}

#Preview("Form — empty") {
    FormView(c: PhoneController.preview(swings: []))
}

#Preview("Paired device") {
    PairedDeviceView(c: PhoneController.preview(swings: DemoData.oneSession))
}

#Preview("Setup") {
    SetupView(c: PhoneController.preview(swings: DemoData.history()))
}

#Preview("Onboarding") {
    OnboardingView(c: PhoneController.preview(swings: []))
}

#Preview("Ensemble chart") {
    EnsembleChart(traces: DemoData.history(sessions: 1, perSession: 30)
        .filter(\.struck).map(\.normalizedTrace))
        .frame(height: 220)
        .padding()
        .background(Color.panel)
}
