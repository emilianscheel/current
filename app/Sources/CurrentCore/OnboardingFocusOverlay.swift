import CoreGraphics
import Foundation

package struct StageLightSample: Equatable, Sendable {
    package let overlayOpacity: CGFloat
    package let beamIntensity: CGFloat
    package let beamExpansion: CGFloat
}

package struct FocusPresentationGeneration: Equatable, Sendable {
    package private(set) var current = 0

    package init() {}

    package mutating func next() -> Int {
        current += 1
        return current
    }

    package func matches(_ value: Int) -> Bool {
        current == value
    }
}

package enum StageLightAnimation {
    package static let duration: TimeInterval = 3
    package static let fadeInDuration: TimeInterval = 0.55
    package static let fadeOutDuration: TimeInterval = 0.65

    package static func sample(
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> StageLightSample {
        let clamped = min(max(elapsed, 0), duration)
        let fadeOutStart = duration - fadeOutDuration
        let opacity: CGFloat
        if clamped < fadeInDuration {
            opacity = smoothStep(CGFloat(clamped / fadeInDuration))
        } else if clamped > fadeOutStart {
            opacity = 1 - smoothStep(
                CGFloat((clamped - fadeOutStart) / fadeOutDuration)
            )
        } else {
            opacity = 1
        }

        guard !reduceMotion else {
            return StageLightSample(
                overlayOpacity: opacity,
                beamIntensity: 0.58,
                beamExpansion: 0
            )
        }

        let normalized = CGFloat(clamped / duration)
        let bloom = sin(normalized * .pi)
        return StageLightSample(
            overlayOpacity: opacity,
            beamIntensity: 0.58 + bloom * 0.22,
            beamExpansion: bloom
        )
    }

    private static func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

package struct FocusWindowObservation: Equatable, Sendable {
    package let id: CGWindowID
    package let processIdentifier: Int32
    package let ownerName: String
    package let frame: CGRect
    package let layer: Int
    package let alpha: Double

    package init(
        id: CGWindowID,
        processIdentifier: Int32,
        ownerName: String,
        frame: CGRect,
        layer: Int = 0,
        alpha: Double = 1
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.ownerName = ownerName
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
    }
}

package enum MicrophonePromptMatcher {
    package static func candidate(
        baselineWindowIDs: Set<CGWindowID>,
        observations: [FocusWindowObservation],
        applicationProcessIdentifier: Int32,
        excludedWindowID: CGWindowID?
    ) -> FocusWindowObservation? {
        let securityOwners = Set([
            "CoreAuthUI",
            "CoreServicesUIAgent",
            "LocalAuthenticationRemoteService",
            "SecurityAgent",
            "UserNotificationCenter",
            "authorizationhost",
        ])

        return observations
            .filter { observation in
                !baselineWindowIDs.contains(observation.id)
                    && observation.id != excludedWindowID
                    && observation.alpha > 0
                    && observation.frame.width >= 220
                    && observation.frame.height >= 100
                    && observation.frame.width <= 900
                    && observation.frame.height <= 700
                    && (observation.processIdentifier
                            == applicationProcessIdentifier
                        || securityOwners.contains(observation.ownerName))
            }
            .max { lhs, rhs in
                candidateScore(
                    lhs,
                    applicationProcessIdentifier: applicationProcessIdentifier,
                    securityOwners: securityOwners
                ) < candidateScore(
                    rhs,
                    applicationProcessIdentifier: applicationProcessIdentifier,
                    securityOwners: securityOwners
                )
            }
    }

    private static func candidateScore(
        _ observation: FocusWindowObservation,
        applicationProcessIdentifier: Int32,
        securityOwners: Set<String>
    ) -> Double {
        let ownerScore = securityOwners.contains(observation.ownerName)
            ? 2_000_000.0 : 1_000_000.0
        let processScore = observation.processIdentifier
                == applicationProcessIdentifier
            ? 500_000.0 : 0
        let layerScore = observation.layer == 0 ? 100_000.0 : 0
        return ownerScore + processScore + layerScore
            - observation.frame.width * observation.frame.height
    }
}
