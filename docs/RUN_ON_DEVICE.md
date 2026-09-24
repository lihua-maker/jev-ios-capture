# Running it on an iPhone

Everything up to signing is already verified in CI: the app and the keyboard extension compile for
the device SDK, the extension is embedded with the right extension point and `RequestsOpenAccess`,
and the capture rules are pinned against 61 fixtures across five font/recogniser/text-size
combinations. What CI cannot do is sign, install, grant permissions or exercise the photo library —
that is what this page is for. It assumes a Mac with Xcode; nothing else.

## 1. Get the code and generate the project

```bash
git clone https://github.com/lihua-maker/jev-ios-capture.git
cd jev-ios-capture
brew install xcodegen          # once
xcodegen generate              # writes JevCopilot.xcodeproj from project.yml
open JevCopilot.xcodeproj
```

The project is generated, not committed, so the app configuration is reviewable as text.

## 2. Set your team, once

Edit **one file**: `Config/Signing.xcconfig`, and replace `YOUR_TEAM_ID`:

```
DEVELOPMENT_TEAM = ABCDE12345
```

Find it with `security find-identity -v -p codesigning` — it is the part in parentheses after your
Apple Development certificate. A free personal team works (it re-signs every 7 days). Leave
everything else alone; `CODE_SIGN_STYLE = Automatic` means no profiles to make by hand.

## 3. If your team cannot create an App Group

The app and the keyboard share the latest analysis through `group.ai.jevcopilot`, which needs a
provisioning profile that grants it. If Xcode reports the capability as unavailable for your team,
open `project.yml`, delete the `entitlements:` blocks under both targets, and re-run
`xcodegen generate`. Nothing else changes: the app detects the missing group at startup and puts the
recommended reply on the **clipboard** instead, and the keyboard's **插入剪贴板** button inserts it.
The app tells you which of the two modes you are in (see the 接口 tab and the 自检 tab).

## 4. Run it

1. Plug in the iPhone, select it as the run destination, press Run.
2. On first launch iOS asks for photo-library access — the app reads the screenshots **you** take,
   locally. Only the judgment request leaves the phone, and only to the endpoint you configure.
3. **接口** tab: pick a preset, paste a key into **判断接口** (that one is required; leave the other
   two empty and they inherit it), then press **测试连通**.
4. Settings → General → Keyboard → Keyboards → Add New Keyboard → **Jev 键盘**, then enable
   **Full Access** (needed for the clipboard handoff and for the keyboard to reach the network).
5. Take a screenshot of a chat, come back to the app, press **分析最新截图**.

## 5. Verify the install in one tap: the 自检 tab

This is the part that exists so nobody has to send screenshots of a private conversation. The app
ships a corpus screenshot and the output recorded for it, runs the whole capture stage on the
device, and prints a pass/fail per check:

| check | what it proves |
|---|---|
| 切分规则复现 fixture | the ported rules, on this device, reproduce the exact recorded bubbles/chrome |
| 本机识别 + 转录 | **this** device's Vision reads the screenshot; reported as character agreement, because box coordinates can differ from the build machine's |
| Keychain 读写 | keys can be stored and read back |
| 判断接口连通 | only when a key is configured: the endpoint answers |
| · 屏幕 | the device geometry, to compare against the corpus (1170×2532 = iPhone 12/13/14) |
| · App Group | whether the keyboard can read the analysis directly or must use the clipboard |

Press **复制结果** and paste that block into the chat — one message, no images, and it says exactly
which layer failed if anything did.

## Known traps

- **`Embedded binary's bundle identifier is not prefixed with the parent app's`** — the keyboard's
  id must start with the app's (`ai.jevcopilot.app` / `ai.jevcopilot.app.keyboard`). Already correct
  in `project.yml`; it only appears if you rename one and not the other.
- **The keyboard compiles but never appears in Settings** — the extension's
  `NSExtensionPointIdentifier` must be `com.apple.keyboard-service`. CI asserts this on every push;
  if you edited `project.yml`, that is the line to check.
- **The keyboard shows nothing** — Full Access is off, or the analysis is older than 15 minutes
  (the keyboard refuses stale results rather than inserting yesterday's reply).
- **XcodeGen reports an unreadable project format** — you have an old XcodeGen writing format 77;
  use Xcode 16+ or `brew upgrade xcodegen`.
- **Display Zoom** changes the logical screen to 375×812, which invalidates the chrome bands the
  capture rules measure. Turn it off for verification.

## What is still unverified after this

Runtime behaviour on a real device — photo-library reads, keyboard insertion, App Group sharing —
and the judgment layer against your own real conversations. Those need the phone, and the 自检 tab
plus one real analysis is the smallest way to close them.