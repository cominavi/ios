fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios asc_check

```sh
[bundle exec] fastlane ios asc_check
```

Verify App Store Connect API access

### ios asc_inventory

```sh
[bundle exec] fastlane ios asc_inventory
```

Show current App Store and TestFlight review state without changing it

### ios build_testflight

```sh
[bundle exec] fastlane ios build_testflight
```

Build a signed TestFlight archive and IPA without uploading it

### ios upload_ipa

```sh
[bundle exec] fastlane ios upload_ipa
```

Upload an existing signed IPA to TestFlight

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload the current version to TestFlight

### ios upload_external_ipa

```sh
[bundle exec] fastlane ios upload_external_ipa
```

Upload an existing IPA, submit it to External Beta, and verify the result

### ios external_beta

```sh
[bundle exec] fastlane ios external_beta
```

Build, upload, submit, and verify an external TestFlight beta

### ios check_external

```sh
[bundle exec] fastlane ios check_external
```

Verify an external TestFlight build without changing App Store Connect

### ios submit_external

```sh
[bundle exec] fastlane ios submit_external
```

Submit an already-uploaded build to External Beta and verify the result

### ios replace_app_review

```sh
[bundle exec] fastlane ios replace_app_review
```

Build a new binary, replace the current App Review submission, and verify it

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload App Store metadata and screenshots without uploading or submitting a build

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
