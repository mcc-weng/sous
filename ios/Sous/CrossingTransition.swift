// ios/Sous/CrossingTransition.swift
import SwiftUI

/// The imperative state machine behind 過場 · the crossing (README §Motion): paper
/// dims in place (620ms), the stage cross-fades in starting at 340ms, and its glow
/// arrives last at 500ms — light comes on last, the way a gas ring does. Reversed and
/// ~220ms faster on the way back to paper. Expressed as explicit, individually staged
/// `withAnimation` calls (not a single declarative `.animation(value:)`) because each
/// layer needs its own delay within one state transition, which a single implicit
/// animation modifier can't express.
///
/// `onSettled` is called once the full sequence completes — used by tests to assert on
/// end state without hand-rolling delays, and unused (nil) by real call sites.
@MainActor
final class CrossingChoreography: ObservableObject {
    @Published private(set) var paperVisible = true
    @Published private(set) var stageVisible = false
    @Published private(set) var paperDimmed = false
    @Published private(set) var stageOpacity: Double = 0
    @Published private(set) var glowOpacity: Double = 0

    func setInitial(showingStage: Bool) {
        paperVisible = !showingStage
        stageVisible = showingStage
        paperDimmed = showingStage
        stageOpacity = showingStage ? 1 : 0
        glowOpacity = showingStage ? 1 : 0
    }

    func crossToStage(reduceMotion: Bool, onSettled: (() -> Void)? = nil) {
        if reduceMotion {
            // README §Accessibility: "Reduce Motion collapses everything to 140ms
            // cross-fades, including the crossing (a straight cut, warning line still
            // shown)" — the crossing specifically becomes a straight cut, not a fast
            // fade (the 140ms figure describes other elements' treatment). Set final
            // state directly, no `withAnimation` — wrapping an instant state change in
            // `withAnimation` is misleading: SwiftUI can't animate a property change on
            // a view in the very same transaction that inserts it (no prior rendered
            // frame to interpolate from), so it would have rendered as an unannounced
            // pop dressed up as an animation call.
            paperDimmed = true
            stageOpacity = 1
            glowOpacity = 1
            stageVisible = true
            paperVisible = false
            onSettled?()
            return
        }
        stageVisible = true // in the tree, still transparent — the 340ms fade-in has something to animate
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.62)) {
            paperDimmed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.28)) {
                self?.stageOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.3)) {
                self?.glowOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.94) { [weak self] in
            self?.paperVisible = false
            onSettled?()
        }
    }

    func crossToPaper(reduceMotion: Bool, onSettled: (() -> Void)? = nil) {
        if reduceMotion {
            // Same straight-cut reasoning as crossToStage's reduceMotion branch.
            paperDimmed = false
            stageOpacity = 0
            glowOpacity = 0
            paperVisible = true
            stageVisible = false
            onSettled?()
            return
        }
        paperVisible = true // in the tree again, still dimmed — the fade back has something to land on
        withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.3)) {
            glowOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.22)) {
                self?.stageOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.5)) {
                self?.paperDimmed = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
            self?.stageVisible = false
            onSettled?()
        }
    }
}

/// One shared crossing implementation used both directions (C1→C2 in `CookModeView`,
/// C3→C4 on the way back) so the choreography can't drift between call sites.
/// `showingStage` drives which side settles; toggling it plays the corresponding
/// direction. `paper`/`stage` are continuously rendered while their tree-presence flag
/// is true — the fade itself is `stageOpacity`/`glowOpacity`, not insertion/removal.
struct CrossingTransition<Paper: View, Stage: View>: View {
    let showingStage: Bool
    @ViewBuilder var paper: () -> Paper
    @ViewBuilder var stage: () -> Stage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var choreography = CrossingChoreography()
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            if choreography.paperVisible {
                paper()
                    .colorMultiply(Color(white: choreography.paperDimmed ? 0.28 : 1.0))
                    .saturation(choreography.paperDimmed ? 0.4 : 1.0)
            }
            if choreography.stageVisible {
                stage()
                    .opacity(choreography.stageOpacity)
                    .overlay(alignment: .bottom) {
                        StageTokens.glow
                            .opacity(choreography.glowOpacity)
                            .allowsHitTesting(false)
                    }
            }
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            choreography.setInitial(showingStage: showingStage)
        }
        .onChange(of: showingStage) { _, newValue in
            if newValue {
                choreography.crossToStage(reduceMotion: reduceMotion)
            } else {
                choreography.crossToPaper(reduceMotion: reduceMotion)
            }
        }
    }
}
