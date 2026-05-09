# Calibrated Coach (Ch7)

Post-workout feedback layer. Pipeline:

```
CoachContext  →  CoachFacts  →  CoachFeedback (text)  →  CoachAudio (mp3)
   (input)     (deterministic)     (LLM narrator)            (TTS)
```

Each stage is a swap point with a protocol at every boundary.

## Build state — 2026-04-27

### Layer 1 — deterministic substrate (DONE)

Every layer below is gated on Layer 1 producing useful, stable, number-grounded facts. That's shipped:

- `Services/Coach/CoachContext.swift` — input bundle, pure value type, Sendable.
- `Services/Coach/CoachContextBuilder.swift` — async composer over `TrainingLoadService`, `ChallengeService`, `AnalyticsService`, `WeeklyScheduleService`, `MaxHRService`, `HealthKitService`, `SigmoidalService`. Pure composition, no new analytics.
- `Services/Coach/CoachFacts.swift` — structured-observation type (Kind, Severity, templateKey, values).
- `Services/Coach/DeterministicCoach.swift` — rule pass with starter rules for milestones, adherence, progress vs. target, CTL delta, TSB recovery, HR-at-pace drift, zone shape.
- `Services/Coach/CoachFeedbackLoader.swift` — view-scoped `@Observable` `@MainActor` async loader, same lifecycle pattern as `WorkoutDetailsLoader`.
- `Models/CoachFeedbackModel.swift` — SwiftData `@Model` for persistence + provenance (narrator/voice/audio metadata). Registered in `Persistence.swift`.
- `Views/WorkoutLog/CoachFeedbackCard.swift` — SwiftUI card. Renders bullets at Layer 1; renders prose when Layer 2 lands. Renders nothing when no `.notable` facts.
- `Views/WorkoutLog/LogWorkoutSheet.swift` — wired. Adds `@Query` for workouts + challenges, instantiates loader, kicks off in `.task`, cancels on disappear, slots card above `HeartRateCard`.
- `Localizable.xcstrings` — 17 fact templates in EN + ES, plus "Coach" section title and the loading placeholder.

The "coach earns the right to speak" rule is enforced at the card render gate — no `.notable` facts means an empty `EmptyView`. Tune by adjusting severity thresholds in `DeterministicCoach.swift`.

### Layer 2 — LLM narrators (NEXT)

When Layer 1 is well-calibrated (after a week or so of dogfooding), add narrators in this order:

1. **`Services/Coach/CoachKeychain.swift`** — three slots (`anthropic`, `gemini`, `elevenLabs`). Mirror `ReclaimKeychain` pattern.
2. **Settings UI** — three secure-text fields with per-key "Test" buttons. Validate on save with one-shot ping. Don't let invalid keys discover themselves at workout-detail-open.
3. **`Services/Coach/CoachNarrator.swift`** — protocol: `narrate(facts:context:) async throws -> String`.
4. **`Services/Coach/AnthropicNarrator.swift`** — `claude-sonnet-4-6`. `POST https://api.anthropic.com/v1/messages`, headers `x-api-key` + `anthropic-version: 2023-06-01`. Build first — gives a quality reference for what "good" feels like.
5. **`Services/Coach/FoundationModelNarrator.swift`** — `@available(iOS 26.0, *)`. `import FoundationModels`, `LanguageModelSession`, `@Generable` struct for typed output. Free, instant, private — should become the everyday default.
6. **`Services/Coach/GeminiNarrator.swift`** — `gemini-2.5-flash` (cheap) or `gemini-2.5-pro` (quality). A/B against Anthropic.

Persona: **future-self-as-coach.** *"You are Kurt, three years from now, looking back at today's workout. Speak to present-Kurt directly. Terse, evidence-based, no encouragement that isn't earned by the data."* The cloned-voice tier (Layer 3) makes this frame land in a way it wouldn't with a generic voice.

When a narrator runs, persist its output in `CoachFeedbackModel.body` and the source facts in `factsJSON`. Cache lookup by `workoutID` — if a feedback row exists for the workout and the workout hasn't been re-edited since, serve the cached text instead of regenerating.

### Layer 3 — voice (LATER)

After Layer 2 has been used for a few weeks and a preferred narrator is identified.

1. **`Services/Coach/CoachVoice.swift`** — protocol: `synthesize(text:voiceID:) async throws -> Data` (mp3).
2. **`Services/Coach/ElevenLabsVoice.swift`** — `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}`, header `xi-api-key`, body has `voice_settings`. Cloned-voice ID stored in `UserPreferencesModel.coachVoiceID`. ~$0.0009/workout at the Creator tier.
3. **`Services/Coach/SystemVoice.swift`** — `AVSpeechSynthesizer` fallback. Free, offline.
4. **`Services/Coach/CoachAudioStore.swift`** — file I/O for `Caches/CoachAudio/{feedbackId}.mp3`. Audio NOT in `CoachFeedbackModel` — file size would bloat CloudKit sync. iOS may evict Caches; `audioGeneratedAt` on the model row tells the player to regenerate on next play if the file is gone.
5. **`Services/Coach/CoachAudioPlayer.swift`** — `AVAudioPlayer` wrapper, `AVAudioSession` configured for `.playback` + `.spokenAudio` so it ducks Spotify rather than silencing it. `@Published` state for play/pause/progress.
6. **UI** — add play button + waveform animation + provider chip to `CoachFeedbackCard`. Default playback to **opt-in** (button labeled "What did I make of that?") rather than auto-play. Auto-play feels great in the demo, overbearing by week three.

### Layer 4 — Spanish hook (LAST)

ElevenLabs voice clones cross languages. Setting `UserPreferencesModel.coachLanguageOverride = "es"` (or honoring system locale) gives passive-immersion reps tied to a daily ritual. Almost free, high-leverage. Files into the [[Learning Threads]] Spanish thread in the vault.

System-prompt variants per language live in `*Narrator.swift` files; pass locale through `CoachContext.locale`.

## Adding a Layer 1 rule

1. Pick a `templateKey` of form `fact.<kind>.<rule>`.
2. Add EN + ES copy to `Localizable.xcstrings` with `%{name}%` placeholders.
3. Add the rule body in `DeterministicCoach.swift` with a comment explaining the threshold's *why*.
4. Decide severity carefully — `.notable` is reserved for observations that genuinely change behavior. Most rules are `.normal`.

## Cost sanity (personal scale)

90-day challenge with one feedback per workout:
- ElevenLabs (cloned voice): ~$0.0009 × 90 = **$0.08**
- Anthropic Sonnet (~2k in / 150 out): ~$0.012 × 90 = **$1.08**
- Total per challenge: well under $2

Constraint is taste, not wallet.
