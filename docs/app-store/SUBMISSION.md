# App Store submission: Duomulator 1.0

Everything App Store Connect asks for, ready to paste, plus the steps in order.

## Ready in the repo

- **Build:** version 1.0 (1), bundle ID `io.kurast.duomulator`, team `8NX8ZBT9WD`, games
  category, privacy manifest, export compliance set to "no non-exempt encryption".
- **Screenshots:** `docs/app-store/iphone-6.3/`, six 1206×2622 PNGs for the "iPhone with Dynamic
  Island (medium display)" slot. A larger 1320×2868 set is in `iphone-6.9/` if the large slot
  is requested.
- **Demo games:** three public-domain games are added on first launch, so App Review has
  something to play.
- **Privacy policy:** `https://airdamien.github.io/duomulator/privacy.html`. It goes live
  once GitHub Pages is on: Settings › Pages › Deploy from branch `main`, folder `/docs`.
- **Upload settings:** `docs/app-store/ExportOptions.plist`.

## Steps

1. **Developer Program.** Team 8NX8ZBT9WD needs an active paid Apple Developer Program
   membership (developer.apple.com › Account).
2. **GitHub Pages.** Turn it on, as above, and check that the privacy URL loads.
3. **Create the app record.** In appstoreconnect.apple.com, go to Apps › **+** › New App:
   - Platform: iOS
   - Name: **Duomulator**. If the name is taken or rejected, try "Duomulator Retro".
   - Primary language: English (U.S.)
   - Bundle ID: `io.kurast.duomulator`. If it isn't in the list yet, run the upload in step
     4 once; automatic signing registers it. Or add it under Certificates, IDs & Profiles ›
     Identifiers.
   - SKU: `duomulator-ios`
   - User access: Full Access
4. **Upload the build.** From the repo:

   ```sh
   xcodebuild archive -project Duomulator.xcodeproj -scheme Duomulator -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build-release/Duomulator.xcarchive \
     -derivedDataPath build-release -allowProvisioningUpdates
   xcodebuild -exportArchive -archivePath build-release/Duomulator.xcarchive \
     -exportOptionsPlist docs/app-store/ExportOptions.plist -exportPath build-release/export \
     -allowProvisioningUpdates
   ```

   Or open `build-release/Duomulator.xcarchive` in Xcode's Organizer and choose
   Distribute App › App Store Connect › Upload. The build shows up under TestFlight after
   about 10 to 30 minutes of processing.
5. **Fill in the version page** (the App Store tab, "1.0 Prepare for Submission") with the
   text below, then attach the build.
6. **App Privacy:** choose **Data Not Collected**.
7. **Pricing and Availability:** set the price to Free and pick countries. For the EU,
   declare trader status under Business. A free hobby app from an individual can declare
   "not a trader", but if you're acting as a business (Kurast), you're a trader and your
   address and contact details are shown.
8. **Add for Review › Submit.**

## Version page text

**Name** (30 max)
```
Duomulator
```

**Subtitle** (30 max)
```
Retro games made for the fold
```

**Promotional text** (170 max, can change without review)
```
Half-fold your iPhone Duo and it becomes a handheld: the game on top, a full controller below. Also plays great fully open, on the outer display and on every iPhone.
```

**Description** (4000 max)
```
Duomulator is a retro game emulator built around iPhone Duo.

HALF-FOLD IT INTO A HANDHELD
Fold the phone partway, like a laptop, and the game moves to the top screen with a full controller on the bottom, never across the crease. Nintendo DS games put the touch screen below the fold, between the d-pad and the buttons, like the original.

EVERY POSE, EVERY IPHONE
Fully open, the game fills the screen with thin outline controls on top that fade away while a controller is connected. On the outer display, the quick actions move to the side bar so the game and controls get the full width. On any other iPhone, Duomulator works like a classic handheld app.

SYSTEMS
• Super Nintendo and NES
• Nintendo 64, with analog stick and C buttons
• Nintendo DS, dual screen with touch
• Genesis / Mega Drive, with automatic 3- or 6-button pads, 32X and Sega CD
• PlayStation, with DualShock analog sticks and multi-disc games
• Arcade: Neo Geo, Capcom CPS and thousands more

FEATURES
• Quick save and load, save slots, and automatic resume
• Fast forward
• MFi, Xbox and PlayStation controllers and keyboards, with per-system remapping
• Touch controls designed for each console
• A library organized by system, with your recently played games first
• Title-screen thumbnails captured on your device
• BIOS manager that recognizes BIOS files automatically
• Three demo games included, to try the controls right away

YOUR GAMES, YOUR DEVICE
Duomulator doesn't include or download games. Add game files and BIOS files you dumped from hardware you own, using the Files app or Finder. Nothing you add ever leaves your iPhone, and Duomulator collects no data.

Duomulator is free, with no ads or in-app purchases. It's built on open-source emulation cores; see Settings › Acknowledgements.
```

**Keywords** (100 max, comma-separated, no spaces after commas). These avoid trademarked
names, which Apple disallows in keywords.
```
emulator,retro,classic,console,handheld,foldable,arcade,gamepad,controller,8-bit,16-bit,savestate
```

**Support URL:** `https://airdamien.github.io/duomulator/`

**Marketing URL** (optional): `https://github.com/airdamien/duomulator`

**Privacy Policy URL:** `https://airdamien.github.io/duomulator/privacy.html`

**Copyright:** `2026 <your name or company>`

**Category:** Games, with Adventure or Action as the sub-category. Secondary category: Entertainment.

**Age rating:** answer **None / No** to every content question, including unrestricted
web access, user-generated content, gambling and contests. The app itself has no
objectionable content. Expect **4+**.

**Screenshots:** upload all six files from `docs/app-store/iphone-6.3/` in numeric order
under **iPhone with Dynamic Island (medium display)**. If App Store Connect also asks for the
large display, use `docs/app-store/iphone-6.9/`.

## App Review information

**Sign-in required:** No.

**Notes** (paste as is):
```
Duomulator is a retro console emulator (App Review Guideline 4.7). It does not include, offer, or download any games; users add game files they own through the Files app, Finder, or the + button.

To test without your own files: three public-domain demo games made for this app are already in the library on first launch (Nintendo > SNES "Rolling Hills (Demo)", Nintendo > DS "Sunset Lake (Demo)", Sega > Genesis "Neon Horizon (Demo)"). Tap one to play with the on-screen controls. Settings > Add Demo Games restores them if deleted.

iPhone Duo: half-fold the device to see the game above the fold and the controller below. Fully open and closed use overlay layouts, and the outer display moves the quick actions to the side bar. On other iPhones the standard layout is used.

The app makes no network requests: no accounts, analytics, tracking, or downloads.
```

**Contact:** your name, phone and email (shown only to App Review).

## Things that could come up in review

- **Content rights.** The App Store build (Release configuration) leaves out the box art
  download, so it shows no third-party content. Answer "No" to the third-party content
  question.
- **The name.** "Duo" echoes Apple's product name. If review objects, use a variant such
  as "Duomulator Retro" or a new name.
- **Licenses.** The non-commercial and GPL cores are discussed in the repo history. Keep
  the app free with no ads, IAP or donation links.
```
