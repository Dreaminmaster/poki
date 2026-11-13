import SwiftUI
import UIKit

// Speaking to Poki from the message field. The interaction is pull request #250's: the empty field's
// one button offers Dictate and Talk with Poki, a talk goes on in the chat with the field as its bar,
// and Talk with Poki without a voice key says so, with a button to the key's form in Settings. The
// old Voice page no longer opens from anywhere a person can reach. The code and the look are this app's:
// glass, Poki's blue and its brand band, the bear's own pictures, the system's type.

/// What the ways-to-speak panel shows.
enum VoiceWays: Equatable {
    /// Dictate and Talk with Poki.
    case choose
    /// Talk with Poki was chosen with no OpenAI key and no voice bridge: what it needs, and where.
    case needsKey
}

/// Over the message field, from its main button: Dictate (Apple's speech recognition, words into the
/// field) and Talk with Poki (a live conversation through OpenAI's Realtime voice). On the same glass
/// as the field.
struct VoiceWaysPanel: View {
    var step: VoiceWays
    var dictate: () -> Void
    var talk: () -> Void
    var addKey: () -> Void
    var close: () -> Void

    var body: some View {
        Group {
            switch step {
            case .choose: choices
            case .needsKey: needsKey
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous), fallback: .bar)
    }

    private var choices: some View {
        VStack(spacing: 2) {
            WayRow(title: "Dictate", detail: "Your words appear in the message field", identifier: "composer.speak.dictate",
                   action: dictate) {
                Image(systemName: "mic.fill").foregroundStyle(Color(.label))
                    .frame(width: 44, height: 44).background(Color(.label).opacity(0.1), in: .circle)
            }
            WayRow(title: "Talk with Poki", detail: "Speak live; Poki answers and acts", identifier: "composer.speak.talk",
                   action: talk) {
                Image(systemName: "waveform").foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(BrandBand.diagonal, in: .circle)
            }
        }
    }

    /// No voice key: Talk with Poki says so and goes straight to the OpenAI key's form in Settings. With
    /// the key there but Live Voice turned off, it says that and goes to Live Voice.
    private var needsKey: some View {
        let off = ModelKeys.hasKey(.openai) && !VoiceDirect.enabled
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(BrandBand.diagonal, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(off ? LocalizedStringKey("Live Voice Is Off") : LocalizedStringKey("No Voice Key Set Up")).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                    Text(off ? LocalizedStringKey("Talk with Poki uses Live Voice on your OpenAI account. Turn it on in Settings. Dictate works without it.")
                             : LocalizedStringKey("Talk with Poki needs an OpenAI API key. Add one in Settings. Dictate works without it."))
                        .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: close) {
                    Text("Not Now").font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(Color(.label).opacity(0.1), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.speak.later")
                Button(action: addKey) {
                    Text(off ? LocalizedStringKey("Open Settings") : LocalizedStringKey("Add Key")).font(.body.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(Tint.blue, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.speak.add-key")
            }
        }
        .padding(8)
    }
}

/// One way to speak: its mark, its name and a line on what it does.
private struct WayRow<Mark: View>: View {
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var identifier: String
    var action: () -> Void
    @ViewBuilder var mark: Mark

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                mark.font(.body.weight(.semibold)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                    Text(detail).font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The message field while you talk with Poki: what the talk is doing and for how long, Poki's voice
/// on or off, and End. End here and End on the Live Activity end the same talk.
struct TalkBar: View {
    var voice: VoiceModel
    var since: Date?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").font(.body.weight(.semibold)).foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: TalkWord.moving(voice.phase))
                .frame(width: 48, height: 48)
                .background(BrandBand.diagonal, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: TalkWord.text(voice.phase)).font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                    .lineLimit(1).contentTransition(.interpolate)
                if let since {
                    Text(since, style: .timer).font(.footnote).monospacedDigit().foregroundStyle(Color(.secondaryLabel))
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button { voice.muted.toggle() } label: {
                Image(systemName: voice.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body.weight(.medium)).foregroundStyle(Color(.label))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .background(Color(.label).opacity(scheme == .dark ? 0.16 : 0.1), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(voice.muted ? "Unmute Poki’s Voice" : "Mute Poki’s Voice"))
            Button { voice.stop() } label: {
                Text("End").font(.body.weight(.semibold)).foregroundStyle(Tint.onSolid)
                    .padding(.horizontal, 20).frame(height: 48)
                    .background(Tint.solid, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("End Talk"))
            .accessibilityIdentifier("composer.talk.end")
        }
        .frame(minHeight: 48)
    }
}

/// The head of a talk under way, at the bottom of the chat: Poki's brand band with the bear for the
/// moment, and what the talk is doing. What is said goes under it as the chat's own bubbles.
struct TalkHeader: View {
    var voice: VoiceModel

    var body: some View {
        HStack(spacing: 12) {
            if let bear = PokiMood.cutout(mood, small: true) {
                Image(uiImage: bear).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 52, height: 52).offset(y: 5)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Talk with Poki").font(.subheadline.weight(.semibold))
                Text(verbatim: TalkWord.text(voice.phase)).font(.footnote).opacity(0.85).contentTransition(.interpolate)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.leading, 10).padding(.trailing, 16).frame(height: 60)
        .background(BrandBand.diagonal, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var mood: PokiMood {
        switch voice.phase {
        case .thinking: .thinking
        case .speaking: .speaking
        default: .listening
        }
    }
}

/// A talk's state in the status words of the app and the Live Activity (Status.xcstrings).
enum TalkWord {
    static func text(_ phase: VoicePhase) -> String {
        switch phase {
        case .off, .connecting: String(localized: "Connecting")
        case .listening, .hearing: StatusWord.listening.text
        case .thinking: StatusWord.thinking.text
        case .speaking: StatusWord.speaking.text
        case .lost(let why): why
        }
    }

    /// Someone is speaking: the waveform moves.
    static func moving(_ phase: VoicePhase) -> Bool { phase == .hearing || phase == .speaking }
}

/// The brand band in the app: the Live Activity card's blues (BrandBand.colours), corner to corner.
extension BrandBand {
    static var diagonal: LinearGradient {
        LinearGradient(colors: colours, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
