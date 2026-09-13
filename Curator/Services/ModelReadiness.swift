import FoundationModels

enum ModelReadiness: Equatable {
    case ready, notEligible, disabled, downloading, visionUnavailable, unavailable
    static func current() -> Self {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.capabilities.contains(.vision) && model.capabilities.contains(.guidedGeneration)
                ? .ready : .visionUnavailable
        case .unavailable(.deviceNotEligible): return .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .disabled
        case .unavailable(.modelNotReady): return .downloading
        case .unavailable: return .unavailable
        }
    }
    var title: String {
        switch self {
        case .ready: "A little space. More room for memories."
        case .notEligible: "An iPhone with Apple Intelligence is needed"
        case .disabled: "Turn on Apple Intelligence"
        case .downloading: "Apple Intelligence is getting ready"
        case .visionUnavailable: "Image understanding isn't available yet"
        case .unavailable: "Apple Intelligence isn't available right now"
        }
    }
    var detail: String {
        switch self {
        case .ready: "Find the repeated shots you can let go of, while keeping the moments you love."
        case .notEligible: "Curator uses on-device image understanding. It needs an iPhone 15 Pro or a later model that supports Apple Intelligence."
        case .disabled: "Enable Apple Intelligence in Settings, then come back. Your photos are analysed on your device."
        case .downloading: "Keep your device connected to Wi-Fi and power while Apple downloads its models, then try again."
        case .visionUnavailable: "Curator needs the iOS 27 image model. Check for software updates and let Apple Intelligence finish downloading."
        case .unavailable: "Try again in a little while. Your photos and review choices are safe."
        }
    }
}
