# Getting WorkoutChallenge to its first build

Files on disk are in their final place. These steps wire them into the
Xcode project and turn the initial build green. Target: **a working app
running in the iOS Simulator with local-only SwiftData storage.**
HealthKit + CloudKit get turned on later.

---

## 1. Open the project

```
open ~/code/WorkoutChallenge/WorkoutChallenge.xcodeproj
```

You'll see three files shown in red in the Project Navigator:

- `ContentView.swift`
- `Item.swift`
- `WorkoutChallengeApp.swift`

They're red because I moved them off disk (into `.trash/` at the project
root). They're the Xcode template files and aren't needed — the real
`WorkoutChallengeApp.swift` lives under `App/` now.

## 2. Remove the red references

Select all three red files, right-click → **Delete** → **Remove Reference**.
(If Xcode offers "Move to Trash", that works too — the files are already
gone, so either option is fine.)

## 3. Add the real source folders

In the Project Navigator, right-click the yellow `WorkoutChallenge` group
(the one right under the project at the top) → **Add Files to
"WorkoutChallenge"…**

In the dialog:

- Navigate into `WorkoutChallenge/` (yes, the subfolder with the same
  name) and select all five folders at once:
  `App`, `Extensions`, `Models`, `Services`, `Views`
- Make sure these boxes are set:
  - **Copy items if needed** — *unchecked* (files are already in place)
  - **Create groups** — *selected* (not "folder references")
  - **Add to targets** — *WorkoutChallenge* checked
- Click **Add**.

## 4. Set deployment target to iOS 17

Project Navigator → click the blue project icon at the top → **WorkoutChallenge**
target → **General** tab → **Minimum Deployments** → set **iOS** to `17.0`.

(SwiftData and the Swift Charts APIs the app uses need iOS 17.)

## 5. Remove the capabilities that Xcode auto-added

When you created the project with SwiftData storage checked, Xcode
generated an entitlements file with iCloud/CloudKit and Push. For a
simulator-only build without an Apple Developer account set up, those
will fail at signing. Strip them:

- Target → **Signing & Capabilities** tab.
- If you see **iCloud**, **Push Notifications**, or **Background Modes**
  panels, hover each one and click the small **×** in the top-right of
  the panel to remove that capability.
- Check `WorkoutChallenge.entitlements` in the Project Navigator — after
  removing the caps above, the `<dict>` should be empty (or Xcode may
  delete the file; either is fine).

## 6. Build and run

- Pick an iPhone simulator at the top of the window (e.g. iPhone 15).
- `⌘R`.
- First launch → tab bar with Calendar / Progress / Analytics / Settings.
  SwiftData creates the local store; the default workout type ("Exercise")
  and default preferences row get seeded on first run.

If the build fails, the most common culprits are:

- A stray reference to one of the deleted template files — double-check
  step 2.
- Deployment target still on iOS 16 — step 4.
- Files not added to the target — click any `.swift` file and check the
  **Target Membership** checkbox in the right inspector.

---

## Turning things on later

### Re-enable CloudKit sync

1. `App/Persistence.swift` → change `cloudKitDatabase: .none` back to
   `.automatic`.
2. Signing & Capabilities → **+ Capability** → **iCloud** → check
   **CloudKit** → create or pick a container (convention:
   `iCloud.com.yourname.WorkoutChallenge`).
3. Rebuild on a real device (CloudKit sync needs one). The simulator
   logs into your Apple ID but sync behavior there is flaky.

### Enable HealthKit

1. Signing & Capabilities → **+ Capability** → **HealthKit**.
2. In the target's **Info** tab, add the two rows from
   `docs/Info.plist.snippet.xml`:
   - `Privacy - Health Share Usage Description`
   - `Privacy - Health Update Usage Description`
3. Install on a real device (simulator HealthKit is very limited).
4. First tap on "Log Workout" will prompt for HealthKit permission.

### Run the sigmoid service tests

`WorkoutChallengeTests/SigmoidalServiceTests.swift` is sitting next to
`.xcodeproj` but not in any target yet.

1. **File → New → Target → iOS Unit Testing Bundle**, name it
   `WorkoutChallengeTests`. Xcode creates a folder with a sample test.
2. Delete the sample test file Xcode made.
3. Right-click the new test group → **Add Files to "WorkoutChallengeTests"…**
   → pick `WorkoutChallengeTests/SigmoidalServiceTests.swift`.
4. Make sure **Target Membership** for that file is *only* the test
   bundle, not the app target.
5. `⌘U` to run.

---

## Housekeeping

- `.trash/` at the project root holds the three deleted template files
  and the empty `ios/` directory tree. It's safe to delete the whole
  thing from Finder once you've confirmed the build works.
- `docs/PORT_NOTES.md` is the original README that shipped with the iOS
  port — useful for webapp-to-native mapping notes.
- `docs/WorkoutChallenge.entitlements.reference` is the full entitlements
  file from the port (with CloudKit + HealthKit keys). Use it as a
  reference when you enable capabilities, or paste values into the
  target's entitlements once those panels are back.
