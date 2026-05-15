import SwiftUI
import Combine

enum PLTutorialTarget: Hashable {
    case createButton
    case textNoteButton
    case photoNoteButton
    case noteEditorBody
    case noteEditorBackButton
    case folderButton
    case folderCard
    case folderMenu
    case noteCard
    case noteMenu
    case readingModeDoneButton
}

enum PLTutorialHoleShape: Equatable {
    case circle
    case roundedRect(CGFloat)
}

enum PLTutorialPresentation: Equatable {
    case intro
    case spotlight
}

enum PLTutorialCardPlacement: Equatable {
    case automatic
    case top
    case bottom
}

enum PLTutorialEvent: Equatable {
    case introContinue
    case createButtonTapped
    case textNoteCreated
    case photoNoteCreated
    case typedText
    case backPressed
    case folderCreated
    case noteDroppedIntoFolder
    case readingModeOpened
    case readingModeClosed
    case noteCardLongPressed
    case noteCardDoubleTapped
    case menuClosed
}

struct PLTutorialStepDescriptor: Identifiable {
    let id: Int
    let title: String
    let body: String
    let prompt: String
    let target: PLTutorialTarget
    let holeShape: PLTutorialHoleShape
    let holePadding: CGFloat
    let event: PLTutorialEvent
    let presentation: PLTutorialPresentation
    let cardPlacement: PLTutorialCardPlacement
}

@MainActor
final class PLTutorialCoordinator: ObservableObject {
    static let steps: [PLTutorialStepDescriptor] = [
        PLTutorialStepDescriptor(
            id: 0,
            title: "Welcome to PaperLink",
            body: "PaperLink keeps text notes, drawings, photos, folders, and reading mode in one place. Text notes are for writing and checklists. Drawing notes are for sketching or handwriting. Photo notes hold camera shots or imported images. Folders keep related notes together, and reading mode turns a folder into a clean stream.",
            prompt: "Tap Start tutorial when you are ready.",
            target: .createButton,
            holeShape: .roundedRect(18),
            holePadding: 10,
            event: .introContinue,
            presentation: .intro,
            cardPlacement: .automatic
        ),
        PLTutorialStepDescriptor(
            id: 1,
            title: "Open Create",
            body: "Tap Create to open the menu. From there you can make a text note, drawing note, photo note, or folder.",
            prompt: "Tap the Create button.",
            target: .createButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .createButtonTapped,
            presentation: .spotlight,
            cardPlacement: .automatic
        ),
        PLTutorialStepDescriptor(
            id: 2,
            title: "Choose Text Note",
            body: "Pick Text Note. PaperLink creates the note immediately and opens the editor so you can start typing right away.",
            prompt: "Tap the Text Note option.",
            target: .textNoteButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .textNoteCreated,
            presentation: .spotlight,
            cardPlacement: .bottom
        ),
        PLTutorialStepDescriptor(
            id: 3,
            title: "Type your note",
            body: "Tap inside the body and write a sentence or two. The checklist button above the note adds checklist items, and the text saves as you type.",
            prompt: "Type something in the note body.",
            target: .noteEditorBody,
            holeShape: .roundedRect(24),
            holePadding: 0,
            event: .typedText,
            presentation: .spotlight,
            cardPlacement: .bottom
        ),
        PLTutorialStepDescriptor(
            id: 4,
            title: "Go back to Library",
            body: "Tap Back once you have typed something. That returns you to the Library.",
            prompt: "Leave the note when you are done typing.",
            target: .noteEditorBackButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .backPressed,
            presentation: .spotlight,
            cardPlacement: .bottom
        ),
        PLTutorialStepDescriptor(
            id: 5,
            title: "Open Create again",
            body: "Open Create one more time and choose the photo option. On a real device, that opens the camera. In Simulator, it falls back to the photo picker.",
            prompt: "Open the create menu again.",
            target: .createButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .createButtonTapped,
            presentation: .spotlight,
            cardPlacement: .automatic
        ),
        PLTutorialStepDescriptor(
            id: 6,
            title: "Take a photo note",
            body: "Tap Take photo(s), then capture a photo or pick one. PaperLink creates the photo note immediately and opens it for you.",
            prompt: "Take or import a photo.",
            target: .photoNoteButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .photoNoteCreated,
            presentation: .spotlight,
            cardPlacement: .top
        ),
        PLTutorialStepDescriptor(
            id: 7,
            title: "Go back to Library",
            body: "Tap Back once you have taken or picked a photo. That returns you to the Library so you can keep going.",
            prompt: "Leave the photo note when you are done.",
            target: .noteEditorBackButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .backPressed,
            presentation: .spotlight,
            cardPlacement: .bottom
        ),
        PLTutorialStepDescriptor(
            id: 8,
            title: "Create a folder",
            body: "Tap Create again, then choose New folder. Name it and confirm the alert so you have somewhere to drop the note next.",
            prompt: "Open the create menu again.",
            target: .createButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .createButtonTapped,
            presentation: .spotlight,
            cardPlacement: .bottom
        ),
        PLTutorialStepDescriptor(
            id: 9,
            title: "Confirm the folder",
            body: "Choose New folder, give it a name, and confirm. The folder you create here is the one you will use for drag and drop next.",
            prompt: "Finish the folder you just started.",
            target: .folderButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .folderCreated,
            presentation: .spotlight,
            cardPlacement: .top
        ),
        PLTutorialStepDescriptor(
            id: 10,
            title: "Drag into a folder",
            body: "Grab the note you created earlier and drag it onto the highlighted folder card. PaperLink moves it immediately and keeps the new order.",
            prompt: "Drop the note onto the folder.",
            target: .folderCard,
            holeShape: .roundedRect(26),
            holePadding: 0,
            event: .noteDroppedIntoFolder,
            presentation: .spotlight,
            cardPlacement: .automatic
        ),
        PLTutorialStepDescriptor(
            id: 11,
            title: "Open Reading Mode",
            body: "Double tap the folder to open its menu, then tap Reading. Reading mode shows everything inside that folder as a simple scrollable stream.",
            prompt: "Tap Reading in the folder menu.",
            target: .folderMenu,
            holeShape: .roundedRect(22),
            holePadding: 0,
            event: .readingModeOpened,
            presentation: .spotlight,
            cardPlacement: .automatic
        ),
        PLTutorialStepDescriptor(
            id: 12,
            title: "Reading Mode",
            body: "Reading mode is the clean view for scanning through a folder. Use the arrows to move between notes, then tap Done to go back to the library.",
            prompt: "Tap Done when you are finished reading.",
            target: .readingModeDoneButton,
            holeShape: .roundedRect(18),
            holePadding: 0,
            event: .readingModeClosed,
            presentation: .spotlight,
            cardPlacement: .automatic
        ),
        PLTutorialStepDescriptor(
            id: 13,
            title: "Double tap a card",
            body: "Double tap the highlighted note card to open the action menu.",
            prompt: "Double tap the note card.",
            target: .noteCard,
            holeShape: .roundedRect(26),
            holePadding: 0,
            event: .noteCardDoubleTapped,
            presentation: .spotlight,
            cardPlacement: .automatic
        ),
        PLTutorialStepDescriptor(
            id: 14,
            title: "Use the card menu",
            body: "The note card menu stays open after the double tap. Try a menu action, or close it when you are done.",
            prompt: "Tap Close to finish this part.",
            target: .noteMenu,
            holeShape: .roundedRect(22),
            holePadding: 0,
            event: .menuClosed,
            presentation: .spotlight,
            cardPlacement: .automatic
        )
    ]

    @Published private(set) var isActive: Bool = false
    @Published private(set) var sessionKey: String? = nil
    @Published private(set) var stepIndex: Int = 0
    @Published private(set) var highlightedNoteID: UUID? = nil
    @Published private(set) var highlightedFolderID: UUID? = nil

    var currentStep: PLTutorialStepDescriptor? {
        guard isActive, Self.steps.indices.contains(stepIndex) else { return nil }
        return Self.steps[stepIndex]
    }

    func present(sessionKey: String, shouldShow: Bool) {
        let isNewSession = self.sessionKey != sessionKey
        self.sessionKey = sessionKey

        if shouldShow {
            if isNewSession || !isActive || !Self.steps.indices.contains(stepIndex) {
                stepIndex = 0
                highlightedNoteID = nil
                highlightedFolderID = nil
            }
            isActive = true
            return
        }

        if isNewSession {
            stepIndex = 0
            highlightedNoteID = nil
            highlightedFolderID = nil
        }
        isActive = false
    }

    func dismiss() {
        isActive = false
        highlightedNoteID = nil
        highlightedFolderID = nil
    }

    func introContinueTapped() {
        advance(matching: .introContinue)
    }

    func createButtonTapped() {
        advance(matching: .createButtonTapped)
    }

    func textNoteCreated(noteID: UUID) {
        highlightedNoteID = noteID
        advance(matching: .textNoteCreated)
    }

    func photoNoteCreated(noteID: UUID) {
        highlightedNoteID = noteID
        advance(matching: .photoNoteCreated)
    }

    func typedText() {
        advance(matching: .typedText)
    }

    func backPressed() {
        advance(matching: .backPressed)
    }

    func folderCreated(folderID: UUID?) {
        highlightedFolderID = folderID
        advance(matching: .folderCreated)
    }

    func noteDroppedIntoFolder(folderID: UUID?) {
        highlightedFolderID = folderID
        advance(matching: .noteDroppedIntoFolder)
    }

    func readingModeOpened() {
        advance(matching: .readingModeOpened)
    }

    func readingModeClosed() {
        advance(matching: .readingModeClosed)
    }

    func noteCardLongPressed(noteID: UUID) {
        highlightedNoteID = noteID
        advance(matching: .noteCardLongPressed)
    }

    func noteCardDoubleTapped(noteID: UUID) {
        highlightedNoteID = noteID
        advance(matching: .noteCardDoubleTapped)
    }

    func menuClosed() {
        advance(matching: .menuClosed)
    }

    private func advance(matching event: PLTutorialEvent) {
        guard let step = currentStep, step.event == event else { return }

        stepIndex += 1
        if !Self.steps.indices.contains(stepIndex) {
            isActive = false
            highlightedNoteID = nil
            highlightedFolderID = nil
        }
    }
}

struct PLTutorialAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [PLTutorialTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [PLTutorialTarget: Anchor<CGRect>], nextValue: () -> [PLTutorialTarget: Anchor<CGRect>]) {
        let next = nextValue()
        for (target, anchor) in next where value[target] == nil {
            value[target] = anchor
        }
    }
}

extension View {
    func tutorialAnchor(_ target: PLTutorialTarget) -> some View {
        anchorPreference(key: PLTutorialAnchorPreferenceKey.self, value: .bounds) { [target: $0] }
    }
}

struct TutorialFlowView: View {
    @EnvironmentObject private var theme: PLThemeStore
    @EnvironmentObject private var tutorial: PLTutorialCoordinator

    let anchors: [PLTutorialTarget: Anchor<CGRect>]
    let allowedTargets: Set<PLTutorialTarget>

    var body: some View {
        GeometryReader { proxy in
            if let step = tutorial.currentStep, allowedTargets.contains(step.target) {
                let frame = resolvedFrame(for: step, in: proxy)
                let containerSize = resolvedContainerSize(for: step, in: proxy)
                ZStack {
                    if step.presentation == .intro {
                        TutorialIntroView(
                            step: step,
                            onSkip: { tutorial.dismiss() },
                            onContinue: { tutorial.introContinueTapped() },
                            topInset: proxy.safeAreaInsets.top,
                            bottomInset: proxy.safeAreaInsets.bottom
                        )
                    } else if let frame {
                        spotlightLayer(step: step, frame: frame, in: containerSize)
                            .allowsHitTesting(false)

                        spotlightCallout(
                            step: step,
                            in: proxy,
                            placement: resolvedCardPlacement(for: step, frame: frame, in: containerSize)
                        )

                        tutorialSkipButton(theme: theme, action: { tutorial.dismiss() })
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipAlignment(for: frame, in: containerSize))
                            .padding(.top, proxy.safeAreaInsets.top + 12)
                            .padding(.horizontal, 16)
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.20), value: tutorial.stepIndex)
                .animation(.easeInOut(duration: 0.20), value: tutorial.isActive)
                .ignoresSafeArea()
            }
        }
    }

    private func resolvedFrame(for step: PLTutorialStepDescriptor, in proxy: GeometryProxy) -> CGRect? {
        if let anchor = anchors[step.target] {
            return proxy[anchor]
        }

        if step.target == .photoNoteButton, let fallback = anchors[.createButton] {
            return proxy[fallback]
        }

        if step.target == .noteMenu, let fallback = anchors[.noteCard] {
            return proxy[fallback]
        }

        return nil
    }

    private func resolvedContainerSize(for step: PLTutorialStepDescriptor, in proxy: GeometryProxy) -> CGSize {
#if canImport(UIKit)
        switch step.target {
        case .noteEditorBody, .noteEditorBackButton:
            return UIScreen.main.bounds.size
        default:
            return proxy.size
        }
#else
        return proxy.size
#endif
    }

    @ViewBuilder
    private func spotlightLayer(step: PLTutorialStepDescriptor, frame: CGRect?, in containerSize: CGSize) -> some View {
        let accent = theme.palette.accent

        ZStack {
            SpotlightMask(frame: frame, holeShape: step.holeShape)
                .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))

            if let frame {
                TutorialPulseRing(
                    frame: expandedFrame(frame, padding: step.holePadding),
                    holeShape: step.holeShape,
                    accent: accent
                )
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    private func resolvedCardPlacement(for step: PLTutorialStepDescriptor, frame: CGRect, in containerSize: CGSize) -> PLTutorialCardPlacement {
        switch step.cardPlacement {
        case .top, .bottom:
            return step.cardPlacement

        case .automatic:
            let topSpace = frame.minY
            let bottomSpace = containerSize.height - frame.maxY
            return bottomSpace >= topSpace ? .bottom : .top
        }
    }

    private func skipAlignment(for frame: CGRect, in containerSize: CGSize) -> Alignment {
        frame.midX > containerSize.width * 0.5 ? .topLeading : .topTrailing
    }

    private func expandedFrame(_ frame: CGRect, padding: CGFloat) -> CGRect {
        frame.insetBy(dx: -padding, dy: -padding)
    }

    @ViewBuilder
    private func spotlightCallout(step: PLTutorialStepDescriptor, in proxy: GeometryProxy, placement: PLTutorialCardPlacement) -> some View {
        let card = TutorialInstructionCard(
            step: step,
            stepNumber: tutorial.stepIndex,
            stepCount: max(1, PLTutorialCoordinator.steps.count - 1)
        )
        .frame(maxWidth: 460)

        VStack {
            if placement == .top {
                card
                    .padding(.top, proxy.safeAreaInsets.top + 16)
            }

            Spacer(minLength: 0)

            if placement == .bottom {
                card
                    .padding(.bottom, proxy.safeAreaInsets.bottom + 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }
}

private struct SpotlightMask: Shape {
    let frame: CGRect?
    let holeShape: PLTutorialHoleShape

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)

        guard let frame else { return path }

        switch holeShape {
        case .circle:
            path.addEllipse(in: frame)
        case .roundedRect(let cornerRadius):
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        }

        return path
    }
}

private struct TutorialPulseRing: View {
    let frame: CGRect
    let holeShape: PLTutorialHoleShape
    let accent: Color

    @State private var pulse: Bool = false

    var body: some View {
        let shape = shapeView

        shape
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .foregroundStyle(accent.opacity(pulse ? 0.90 : 0.72))
            .shadow(color: accent.opacity(0.10), radius: 2.5, x: 0, y: 0)
            .opacity(pulse ? 0.95 : 0.86)
            .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: pulse)
            .onAppear {
                pulse = true
            }
    }

    @ViewBuilder
    private var shapeView: some View {
        switch holeShape {
        case .circle:
            Circle()
                .strokeBorder(lineWidth: 3)
        case .roundedRect(let cornerRadius):
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(lineWidth: 3)
        }
    }
}

private struct TutorialInstructionCard: View {
    @EnvironmentObject private var theme: PLThemeStore

    let step: PLTutorialStepDescriptor
    let stepNumber: Int
    let stepCount: Int

    var body: some View {
        let p = theme.palette

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Step \(stepNumber) of \(stepCount)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(p.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(p.accent.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(p.accent.opacity(0.22), lineWidth: 1)
                    )

                Spacer(minLength: 0)
            }

            Text(step.title)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(p.textPrimary)

            Text(step.body)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(step.prompt)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(p.textPrimary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(p.card.opacity(0.98))
                .shadow(color: .black.opacity(0.07), radius: 10, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(p.outline, lineWidth: 1)
        )
    }
}

private func tutorialSkipButton(theme: PLThemeStore, action: @escaping () -> Void) -> some View {
    let p = theme.palette

    return Button(action: action) {
        Text("Skip tutorial")
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(p.railButton)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(p.outline, lineWidth: 1)
            )
    }
    .buttonStyle(.plain)
    .foregroundStyle(p.textPrimary)
    .accessibilityLabel("Skip tutorial")
}

private struct TutorialIntroView: View {
    @EnvironmentObject private var theme: PLThemeStore

    let step: PLTutorialStepDescriptor
    let onSkip: () -> Void
    let onContinue: () -> Void
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        let p = theme.palette

        ZStack {
            p.background
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(step.title)
                                .font(.system(size: 34, weight: .heavy))
                                .foregroundStyle(p.textPrimary)

                            Text(step.body)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(p.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        tutorialSkipButton(theme: theme, action: onSkip)
                    }
                    .padding(.top, topInset + 16)
                    .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            tutorialIntroChip(icon: "doc.text", title: "Text")
                            tutorialIntroChip(icon: "pencil.tip", title: "Draw")
                            tutorialIntroChip(icon: "photo.on.rectangle", title: "Photos")
                            tutorialIntroChip(icon: "folder", title: "Folders")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("PaperLink saves automatically while you work. The tutorial will now show you the main gestures and where they live.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 12) {
                            introBullet(icon: "doc.text", title: "Write notes", detail: "Create text notes, checklists, and quick reminders without pressing save.")
                            introBullet(icon: "folder.badge.plus", title: "Organize", detail: "Group work into folders and keep related notes together.")
                            introBullet(icon: "hand.draw", title: "Gesture guide", detail: "Learn tap, double tap, and drag and drop on real app controls.")
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(p.canvas.opacity(0.90))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(p.outline, lineWidth: 1)
                                )
                        )

                        Button(action: onContinue) {
                            Text("Start tutorial")
                                .font(.system(size: 16, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(p.accent)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start tutorial")
                    }
                    .padding(20)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(p.card.opacity(0.98))
                            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(p.outline, lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, bottomInset + 16)
            }
        }
    }

    private func tutorialIntroChip(icon: String, title: String) -> some View {
        let p = theme.palette

        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))

            Text(title)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(p.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(p.railButton)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private func introBullet(icon: String, title: String, detail: String) -> some View {
        let p = theme.palette

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(p.accent.opacity(0.14))

                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p.textPrimary)

                Text(detail)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
