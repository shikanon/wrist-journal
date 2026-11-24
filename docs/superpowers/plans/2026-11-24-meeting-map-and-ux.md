# Meeting Map and Experience Polish Implementation Plan

> **For agentic workers:** Use the repository's native SwiftUI patterns and work through the acceptance steps in order.

**Goal:** Show the recorded meeting area in Apple MapKit and make the availability of source audio understandable at a glance.

**Architecture:** A phone-only `MeetingLocationView` renders the existing optional location in both recording details and daily reports. Review controls use the existing `JournalStore.sourceAudio` status, so actual file availability determines whether a row offers playback or only shows the timestamp.

**Tech stack:** SwiftUI, MapKit, existing Swift regressions, XCTest build and simulator render probes.

### 1. Show the recorded area

- [x] Update `Tests/PhoneUITests.swift` to check `meeting-location.open-maps` in recording details and in a report after cleanup; check that the old coordinate row is absent.
- [x] Add `Phone/MeetingLocationView.swift` to the iOS group and Sources phase in `WristJournal.xcodeproj/project.pbxproj`. Validate the stored coordinates with `CLLocationCoordinate2DIsValid`, use a minimum viewport of 900 m, and scale it to the reported accuracy. Use `Map(initialPosition: .region(region), interactionModes: [])` so vertical list scrolling remains available. Draw a `MapCircle` for known accuracy, a marker for unknown accuracy, and an accessible `Link` to Apple Maps. Show a text state if the stored location is missing or invalid.
- [x] Replace the coordinate rows in `Phone/WristJournalPhone.swift` and `Phone/JournalReviewView.swift`:

```swift
MeetingLocationView(location: entry.location)
MeetingLocationView(location: meeting.location)
```

- [x] In `Shared/MeetingAnalysis.swift`, keep the optional heart-rate context while omitting the recorded coordinates from new AI-generated minutes. Update the matching setting and permission text. Leave previous minutes and export data intact.

### 2. Clarify audio availability

- [x] In `Phone/WristJournalPhone.swift`, gate playback/export on `journal.store.sourceAudio(id).url`; show distinct states for cleanup, absent local audio, and damage. Keep remote Watch processing eligibility separate from local playback.
- [x] In `Phone/JournalReviewView.swift`, render a tappable marker or citation when `audio.url != nil`, otherwise render its existing time as text. For a report without meetings, do not suggest cleanup is pending. Show the meeting sections before the health section.

### 3. Verify and hand off

- [x] Build `PhoneUITests` for `generic/platform=iOS Simulator`, build `WristJournal` Release for `generic/platform=iOS`, and run the core and daily-archive fixture regressions. Inspect the two native map screens and the empty state in the simulator.
- [x] Add Apple Maps handoff, approximation, offline behavior, and the screen-reader description to the README's open device checklist. Record additional UX findings with their entry point and verification criteria in `docs/体验优化清单.md`.

**Verification:** 103 core and 37 continuity checks passed; the daily cleanup fixture retained the saved meeting location. Both map screens rendered the stored radius and Apple Maps link; the no-location screen rendered its empty state. The simulator showed the map grid without street tiles. The UI test bundle compiled but was not executed, and actual tile loading, opening Apple Maps, VoiceOver, and scrolling are in the README's open device checklist.
