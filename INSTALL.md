# How to install PdfReader

This guide shows you how to install PdfReader, step by step.
Each step has a picture placeholder. The text works without the pictures too.

- [Android](#android)
- [iPhone](#iphone)
- [Updating](#updating)
- [Uninstalling](#uninstalling)

<!-- Screenshots will be added later; every step is also written out in text. -->

---

## Android

PdfReader works on **Android 8.0 or newer**.

It is not in the Google Play Store. You download the app file (called an **APK**) from GitHub and install it yourself.
This is safe if you download it from the official page below.

### Step 1: Download the APK

1. On your phone, open your web browser (for example **Chrome**).
2. Go to the release page:
   **https://github.com/MANISH50/PdfReader/releases**
   Link: https://github.com/MANISH50/PdfReader/releases/latest
3. Find the newest release at the top (it says **Latest**).
4. Scroll down to **Assets**. Tap it if it is closed.
5. Tap the file that ends in **.apk** (for example `PdfReader-1.0.0.apk`).
   The file is called **PdfReader-v1.0.0.apk** (works on almost all phones). If your phone is new (64-bit), the smaller **PdfReader-v1.0.0-arm64-v8a.apk** also works.
6. If the browser asks "Do you want to download this file?", tap **Download**.
7. Wait until the download is finished. You see a message at the bottom of the screen or in the notification bar.

![Release page with the APK file](docs/images/install-android-1.png)

> **Tip:** Only download PdfReader from the GitHub page above. Do not trust copies from other websites.

### Step 2: Allow "Install unknown apps"

Android blocks apps that do not come from the Play Store. You must allow **one** app
(your browser or your file manager) to install the APK. You turn this off again later (Step 5).

The easiest way:

1. Tap the downloaded file (in the notification, or in the browser's **Downloads** list).
2. Android shows a message like **"For your security, your phone is not allowed to install unknown apps from this source."**
3. Tap **Settings** in that message.
4. Turn on **Allow from this source**.
5. Tap the **back** arrow. The install screen opens.

![Install unknown apps switch](docs/images/install-android-2.png)

If you do not see that message, change the setting by hand. The menu names are a little different on each brand:

| Phone | Where to find the setting |
|---|---|
| **Google Pixel** and most phones | **Settings** ▸ **Apps** ▸ **Special app access** ▸ **Install unknown apps** ▸ choose **Chrome** (or **Files**) ▸ turn on **Allow from this source** |
| **Samsung** | **Settings** ▸ **Apps** ▸ tap the **⋮** menu (top right) ▸ **Special access** ▸ **Install unknown apps** ▸ choose **Chrome** or **My Files** ▸ turn on **Allow from this source** |
| **Xiaomi / Redmi / POCO** | **Settings** ▸ **Apps** ▸ **Manage apps** ▸ choose **Chrome** (or **File Manager**) ▸ **Install unknown apps** ▸ turn on **Allow from this source**. On some versions: **Settings** ▸ **Privacy protection** ▸ **Special permissions** ▸ **Install unknown apps**. |

> **Tip:** If you cannot find it, open **Settings** and type **unknown** in the search box at the top.

### Step 3: Install

1. Open the downloaded APK again (from the notification, the browser's **Downloads**, or the **Files** app ▸ **Downloads**).
2. You see "Do you want to install this app?". Tap **Install**.
3. Wait a few seconds. Then tap **Open** or **Done**.

![Install button](docs/images/install-android-3.png)

### Step 4: If you see a Google Play Protect warning

Google Play Protect may say **"App blocked to protect your device"** or **"Unsafe app blocked"**.
This happens because the app is new and does not come from the Play Store. It does **not** mean the app is harmful.

1. Tap **More details** (or the small arrow).
2. Tap **Install anyway**.

If Play Protect asks to **send the app for scanning**, you can say yes or no. It does not change how PdfReader works.

![Play Protect warning](docs/images/install-android-4.png)

> **Tip:** If you want to be sure the file is genuine, check it first. See [Check that the download is genuine](#check-that-the-download-is-genuine-optional).

### Step 5: Turn "Install unknown apps" off again

This is important for your safety. After PdfReader is installed, turn the setting off again:

1. Open **Settings**.
2. Go to the same place as in Step 2 (for example **Apps** ▸ **Special app access** ▸ **Install unknown apps**).
3. Tap the app you allowed (for example **Chrome**).
4. Turn off **Allow from this source**.

PdfReader keeps working. You only need to turn it on again when you install an update.

![Turn the switch off](docs/images/install-android-5.png)

### Check that the download is genuine (optional)

Each release page shows a **SHA-256 checksum** for the APK. It is a long code made of letters and numbers.
If your file gives the same code, the file is exactly the one we published.

Each release has a file called **SHA256SUMS.txt** with the checksums.

Copy the APK to a computer, then open a terminal in the folder with the file:

- **Windows** (PowerShell):
  ```powershell
  Get-FileHash .\PdfReader-1.0.0.apk -Algorithm SHA256
  ```
- **macOS**:
  ```sh
  shasum -a 256 PdfReader-1.0.0.apk
  ```
- **Linux**:
  ```sh
  sha256sum PdfReader-1.0.0.apk
  ```

Compare the result with the code on the release page. Every character must match (capital or small letters do not matter).
If they are different, **do not install the file**. Download it again from the official page.

> **Tip:** Some file manager apps on Android can also show the SHA-256 of a file.

### Set PdfReader as your default PDF app

Then every PDF you tap opens in PdfReader.

1. Open the **Files** app (or **My Files** on Samsung).
2. Tap any PDF file.
3. Android asks which app to use. Choose **PdfReader**.
4. Tap **Always**.

![Open with PdfReader, Always](docs/images/install-android-6.png)

**If PDFs open in another app and Android does not ask:** another app is already the default. Clear it first:

1. Open **Settings** ▸ **Apps**.
2. Find the app that opens your PDFs now (for example **Drive**, **Adobe Acrobat** or **WPS Office**) and tap it.
3. Tap **Open by default** (on some phones: **Set as default** or **Default apps**).
4. Tap **Clear defaults** (or turn off **Open supported links**, depending on your phone).
5. Tap a PDF again. Choose **PdfReader** ▸ **Always**.

![Clear defaults](docs/images/install-android-7.png)

> **Tip:** PdfReader also has a short guide for this inside the app.
> In the app: **Settings** ▸ **How to open PDFs with PdfReader**.

---

## iPhone

PdfReader works on **iOS 15 or newer**.

Apple only lets you install apps in a few ways. There is no simple "download a file" option like on Android.
Choose the option that fits you:

| Option | Who it is for | What it needs | How long the app works |
|---|---|---|---|
| **A. TestFlight** | Most people | The developer must have a paid Apple Developer account. You need an invite link. | Each build works for **90 days**. New builds come as updates. |
| **B. Xcode on a Mac** | People with a Mac | A Mac, Xcode and a free Apple ID | **7 days**, then you must install it again |
| **C. App Store** | Everyone (in the future) | The developer needs a paid account and Apple's review | Normal app, no time limit |

Right now only option (b) — installing with Xcode — is available. TestFlight and the App Store need a paid Apple Developer account, which this project does not have yet.

### Option A: TestFlight

TestFlight is Apple's official app for testing apps before they are in the App Store.

**What it needs:** the developer pays for the **Apple Developer Program** (USD 99 per year) and sends out an invite link.

1. On your iPhone, install **TestFlight** from the App Store. It is free and made by Apple.
2. Open the PdfReader invite link on your iPhone.
   
3. Tap **Accept**, then **Install**.
4. PdfReader appears on your home screen.

![TestFlight install](docs/images/install-ios-testflight-1.png)

> **Note:** each TestFlight build stops working after **90 days**. The developer uploads new builds before that.
> TestFlight tells you when an update is ready.

### Option B: Build with Xcode on a Mac (free Apple ID)

You can install PdfReader yourself with a free Apple ID. This needs a Mac.

**Important limits of a free Apple ID:**
- The app **stops working after 7 days**. Then you must connect your iPhone and install it again from Xcode.
  Your files and notes inside the app stay if you install over the old app (do not delete it first).
- You can have at most **3 apps** installed this way at the same time.

**Steps:**

1. **Install Xcode.** Open the **App Store** on your Mac, search for **Xcode** and install it. It is large and can take a while.
2. Open Xcode once and accept the license. Let it install extra components.
3. **Install Flutter 3.50.0.** Follow the steps on https://docs.flutter.dev/get-started/install/macos.
   Then run `flutter doctor` in **Terminal** and fix anything it reports for iOS.
4. **Get the code.** In **Terminal**:
   ```sh
   git clone https://github.com/MANISH50/PdfReader.git
   cd PdfReader
   flutter pub get
   ```
5. **Open the project in Xcode:**
   ```sh
   open ios/Runner.xcworkspace
   ```
   Open the `.xcworkspace` file, not the `.xcodeproj` file.
6. **Add your Apple ID.** In Xcode, choose **Xcode** ▸ **Settings** ▸ **Accounts**. Tap **+** and sign in with your Apple ID.
7. **Choose your team.**
   1. In the left panel, click **Runner** (the blue icon at the top).
   2. Under **Targets**, click **Runner**.
   3. Open the **Signing & Capabilities** tab.
   4. Turn on **Automatically manage signing**.
   5. In **Team**, choose **Your Name (Personal Team)**.
8. **Change the bundle identifier if needed.** If Xcode shows an error like "Failed to register bundle identifier",
   change **Bundle Identifier** to something unique, for example `com.yourname.pdfreader`.
9. **Connect your iPhone** to the Mac with a cable. Unlock the iPhone. If it asks **Trust This Computer?**, tap **Trust**.
10. **Turn on Developer Mode** on the iPhone (iOS 16 and newer):
    1. Open **Settings** ▸ **Privacy & Security**.
    2. Scroll down and tap **Developer Mode**. Turn it on.
    3. The iPhone restarts. After the restart, tap **Turn On** and enter your passcode.

    > If you do not see **Developer Mode**, try step 11 once first. Then it appears.
11. **Run the app.** At the top of Xcode, choose your iPhone as the device. Then click the **Run** button (▶).
    Or run `flutter run --release` in **Terminal**.
12. **Trust the developer** on the iPhone. The first time, iOS says "Untrusted Developer". Then:
    1. Open **Settings** ▸ **General** ▸ **VPN & Device Management**.
    2. Under **Developer App**, tap your Apple ID.
    3. Tap **Trust "your Apple ID"**, then **Trust** again.
13. Open **PdfReader** from your home screen.

![Xcode signing settings](docs/images/install-ios-xcode-1.png)
![Trust the developer](docs/images/install-ios-xcode-2.png)

> **Tip:** Set a reminder for 6 days later. Then reconnect your iPhone and repeat step 11 before the app stops working.

### Option C: App Store

To be in the App Store, the developer needs a paid **Apple Developer Program** account and must pass **Apple's review**.
When PdfReader is in the App Store, you just tap **Get**.



### Open PDFs with PdfReader on iPhone

iPhone has **no setting for a default PDF app**. You choose PdfReader each time:

**From the Files app:**
1. Open **Files**.
2. Touch and hold the PDF (long-press).
3. Tap **Share**.
4. Tap **PdfReader** in the row of apps. If you do not see it, swipe left and tap **More**.

**From other apps** (Mail, Safari, WhatsApp and others):
1. Open the PDF.
2. Tap the **Share** button (a square with an arrow up) or **Open in…**.
3. Choose **PdfReader**.

![Share to PdfReader](docs/images/install-ios-open-1.png)

> **Tip:** In the share row, tap **More** ▸ **Edit**, and move PdfReader to **Favorites**. Then it is always at the front.

---

## Updating

### Android

1. Download the newer APK from the [release page](https://github.com/MANISH50/PdfReader/releases) (see [Step 1](#step-1-download-the-apk)).
2. Allow **Install unknown apps** again for a moment (see [Step 2](#step-2-allow-install-unknown-apps)).
3. Open the APK and tap **Update** (or **Install**).
4. Turn **Install unknown apps** off again.

Install the new version **over** the old one. Your recent files, notes and settings stay,
because every official release is signed with the same key.

> **Warning:** Do **not** uninstall the old version first. If you uninstall, you lose your recent files list,
> notes, highlights and settings that are stored in the app.
>
> If Android says **"App not installed"** or **"package conflicts with an existing package"**, the new file was signed
> with a different key (for example, you built one version yourself). Then you must uninstall first, and your app data is lost.
> Save copies of your edited PDFs before you do this.

PdfReader cannot check for updates by itself, because it has no internet access. Look at the release page from time to time,
or "Watch" the repository on GitHub (**Watch** ▸ **Custom** ▸ **Releases**) to get an email.

### iPhone

- **TestFlight:** TestFlight tells you when a new build is ready. Open **TestFlight** and tap **Update**.
  You can also turn on automatic updates in TestFlight.
- **Xcode:** get the newest code (`git pull`, then `flutter pub get`) and run the app from Xcode again (Option B, step 11).
  Do not delete the app first. Then your data stays.
- **App Store:** updates come like any other app. Check **App Store** ▸ your profile picture ▸ **Updates**.

---

## Uninstalling

**Android:** touch and hold the PdfReader icon ▸ **Uninstall** (or **App info** ▸ **Uninstall**).
**iPhone:** touch and hold the PdfReader icon ▸ **Remove App** ▸ **Delete App**.

**What is removed:**
- Everything PdfReader stores inside the app: the recent files list, reading positions, bookmarks, notes, highlights,
  drawings and signatures that are not saved into a PDF, settings, and copies of files you opened with **Open with** or **Share**.
- PdfReader has no cloud and no account, so **nothing is kept anywhere else**. There is no way to get this data back.

**What is NOT removed:**
- Your original PDF files in **Files**, **Downloads**, Google Drive, iCloud Drive and other places.
- Copies you saved or exported to those places (for example `report (edited).pdf`).

> **Tip:** Before you uninstall, export any PDFs that have notes you want to keep. Use **Save as copy** or **Share**.
