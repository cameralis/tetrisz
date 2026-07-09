# Firebase setup for accounts, ELO and friends (one-time, manual)

The social features (accounts, global ELO ranking, friends, invites, push)
authenticate with **Firebase Auth** and verify ID tokens on the Cloudflare
Worker. Everything is already wired behind an injectable `AuthService`
(`app/lib/src/auth/auth_service.dart`) and ships today in the
"unconfigured" state: the Account screen explains that sign-in is disabled,
and every backend route that needs auth returns 401.

These steps need the project owner (Apple/Google credentials) and cannot be
automated:

## 1. Create the Firebase project

1. https://console.firebase.google.com → *Add project* (suggested id:
   `tetrisz-app`). Analytics off is fine.
2. *Authentication → Sign-in method*: enable **Apple**, **Google** and
   **Email/Password**.

## 2. Register the apps

- **iOS/macOS**: add an Apple app with bundle id `one.tear.tetrisz`;
  download `GoogleService-Info.plist` into `app/ios/Runner/` and
  `app/macos/Runner/`. In Xcode, add the *Sign in with Apple* capability to
  both Runner targets (macOS keeps App Sandbox OFF — see the build memory).
- **Android**: add an Android app with package `com.szabi.tetris`; download
  `google-services.json` into `app/android/app/`.

## 3. Wire the Flutter side

```bash
cd app
fvm flutter pub add firebase_core firebase_auth google_sign_in sign_in_with_apple
fvm dart pub global activate flutterfire_cli
flutterfire configure   # generates lib/firebase_options.dart
```

Then implement `FirebaseAuthService` (the `AuthService` interface has the
exact surface: `account`, `idToken()`, the three sign-in methods, `signOut`)
and install it in `main()`:

```dart
await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
Auth.install(FirebaseAuthService());
```

## 4. Point the Worker at the project

```bash
cd backend
# wrangler.toml: set FIREBASE_PROJECT_ID = "<your project id>"
pnpm run deploy
```

Token verification (`backend/src/auth.ts`) fetches Google's securetoken
JWKS at runtime; no secret is needed on the Worker for auth. (Push
notifications later need a service-account key — separate step in the FCM
issue.)

## 5. Verify

- `cd backend && pnpm test` (already green with the built-in test keypair).
- Run the app, open **Account** from the home screen, sign in, set a display
  name, and check the friend code renders. The profile round-trips through
  `GET/PUT /api/profile` with the real Firebase token.
