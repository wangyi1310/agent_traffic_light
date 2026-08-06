public enum TrafficLightLamp: Hashable, Sendable {
    case red
    case yellow
    case green
}

public enum TrafficLightAnimation {
    public static func litLamps(
        for state: TrafficLightState,
        phase: Int
    ) -> Set<TrafficLightLamp> {
        switch state {
        case .idle:
            return []
        case .thinking:
            switch phase % 3 {
            case 0: return [.red]
            case 1: return [.yellow]
            default: return [.green]
            }
        case .executing:
            return phase.isMultiple(of: 2) ? [] : [.yellow]
        case .completed:
            return [.green]
        case .error:
            return phase.isMultiple(of: 2) ? [] : [.red]
        }
    }
}
