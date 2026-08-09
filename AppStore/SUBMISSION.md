# App Store submission profile

This file records the intended App Store Connect values for ComiNavi 1.0. The
uploadable localization files live under `fastlane/metadata`; Japanese is the
primary language and English (U.S.) is the secondary localization.

## App record

| Field | Value |
| --- | --- |
| Bundle ID | `llc.mikunet.cominavi` |
| Version | `1.0` |
| Prepared build | `2026080501` |
| Primary language | Japanese |
| Category | Navigation |
| Secondary category | Reference |
| Price | Free |
| Copyright | 2026 MikuNet LLC |
| Marketing URL | `https://cominavi.net/` |
| Support URL | `https://cominavi.net/` |
| Privacy policy URL | `https://cominavi.net/privacy/` |
| Content rights | Uses third-party content |
| Non-exempt encryption | No (`ITSAppUsesNonExemptEncryption = false`) |
| Made for Kids | No |
| Release | Manual after approval |
| Phased release | Off for 1.0 |

The support, marketing, and privacy URLs were publicly reachable on
2026-08-04. The standard Apple EULA is sufficient; the app has no purchases,
subscriptions, ads, or custom license agreement.

## Age rating answers

The committed `fastlane/age_rating.json` is intentionally conservative because
the Circle.ms catalog can contain R18 works and externally authored circle cuts,
descriptions, and X shinagaki posts.

| Capability or content | Answer |
| --- | --- |
| Age assurance / parental controls | No / No |
| Unrestricted web access | No; links open outside the app |
| User-generated content | Yes |
| Social media | No |
| Messaging and chat | No |
| Advertising | No paid advertising |
| Mature or suggestive themes | Frequent |
| Sexual content or nudity | Infrequent |
| Graphic sexual content and nudity | None |
| Profanity, horror, weapons, cartoon or realistic violence, alcohol references | Infrequent |
| Gambling, simulated gambling, contests, and loot boxes | None |
| Rating override | 18+ |

Graphic sexual content must remain `None`: an app declaring any frequency for
that category becomes Unrated and cannot be published on the App Store. If
production catalog or shinagaki content can display explicit uncensored images,
it must be filtered before submission rather than described with a lower answer.

## App privacy answers

Select **Yes, we collect data from this app**. The answers must include the app's
own behavior and Sentry, PostHog, Circle.ms, and cominavi.net processing.

| Data type | Purpose | Linked to user | Tracking |
| --- | --- | --- | --- |
| Name (Circle.ms display name) | Analytics | Yes | No |
| User ID (Circle.ms account ID) | App Functionality, Analytics | Yes | No |
| Other User Content (favorite metadata, notes, and X posts shared to ComiNavi) | App Functionality | Yes | No |
| Product Interaction | Analytics | Yes after sign-in | No |
| Other Usage Data | Analytics | Yes after sign-in | No |
| Crash Data | App Functionality, Analytics | Yes after sign-in | No |
| Performance Data | App Functionality, Analytics | Yes after sign-in | No |
| Other Diagnostic Data | App Functionality, Analytics | Yes after sign-in | No |
| Other Data Types (Circle.ms R18 display preference) | Analytics | Yes | No |

Do not select location as collected. Location and heading are processed on the
device while Where Am I is open and are not retained or sent to the operator.
Do not select email address: Circle.ms handles the sign-in page and ComiNavi does
not receive the user's Circle.ms email or password.

The app privacy manifest now matches the production behavior where
`AppTrack.user` attaches the Circle.ms user ID and display name to Sentry and
identifies the same user in PostHog. If that identification is removed before
release, the linked-data answers and manifest can be reduced accordingly.

## Screenshots

The upload set contains three Japanese screenshots for each required device
family:

- iPhone 6.5-inch: 1284 x 2778
- iPad 13-inch: 2064 x 2752

They are staged in Fastlane's locale layout at `fastlane/screenshots/ja`.
Contact sheets are intentionally excluded. App Store Connect can use the
Japanese primary-language set as the fallback for the English localization.

## App Review information

The reviewer notes are committed at
`fastlane/metadata/review_information/notes.txt`. A working Circle.ms review
account is mandatory because the production build contains no demo catalog.

Keep review contact details and Circle.ms credentials outside Git. The upload
lane requires these environment variables:

- `COMINAVI_REVIEW_FIRST_NAME`
- `COMINAVI_REVIEW_LAST_NAME`
- `COMINAVI_REVIEW_PHONE`
- `COMINAVI_REVIEW_EMAIL`
- `COMINAVI_REVIEW_DEMO_USER`
- `COMINAVI_REVIEW_DEMO_PASSWORD`

Prefer a dedicated review account rather than a developer's personal account.
The review account must be able to authorize the app and access an available
catalog throughout the review period.

## Safe metadata upload

The `upload_metadata` lane uploads metadata, screenshots, age rating, and review
information. It explicitly does not upload a binary or submit the version for
review.

For App Store Connect API-key authentication, set `ASC_KEY_ID`, `ASC_ISSUER_ID`,
and `ASC_KEY_FILEPATH`. The `.p8` file must stay outside this repository. If no
API key is configured, Fastlane will request an authenticated Apple account.

```sh
cd /Users/galvin/repos/cominavi/ios
fastlane ios upload_metadata
```

Before the final submission, confirm in App Store Connect that build
`1.0 (2026080501)` has finished processing, select it for version 1.0, set
content rights to **Uses Third-Party Content**, publish the privacy answers,
and run App Review precheck. Submit manually only after those checks pass.

## Release blockers that metadata cannot resolve

- App Store Connect authentication is not available in the current browser or
  shell session, so the live app record and build processing state are not yet
  verified.
- The App Review contact phone number and a dedicated review account must be
  supplied securely.
- The operator must confirm it has permission to redistribute Circle.ms catalog
  data and X post text/images in the app. Declaring third-party content is not a
  substitute for having the necessary rights.
- Because externally authored content is surfaced, confirm the shipped content
  filter and reporting path satisfy the App Review rules for objectionable or
  user-generated content before pressing Submit for Review.
