# C104 demo catalog

Debug and Staging builds can open an offline C104 catalog through the same catalog data layer used for Circle.ms downloads. The two SQLite resources live under `ComiNavi/Resources/DemoCatalogs/C104` and are opened read-only from the application bundle.

Regenerate them from the archived production data with:

```sh
Scripts/prepare-demo-catalog.sh \
  /absolute/path/to/archived-productiondata
```

The main database retains the complete C104 catalog. The image database retains every circle cut and all shared images (cover art, venue maps, and genre overlays), so Demo data exercises the same image-loading behavior as a downloaded catalog.

If the generated SQLite files intentionally change, update their SHA-256 fingerprints in `DemoCatalogSource`; those fingerprints also invalidate the derived map index.

TestFlight and App Store builds exclude the bundled files and download the App Review copy from `https://cominavi.net/api/v2/review-demo/catalogs/c104/v2/`. Debug and Staging builds use the bundled files, so demo mode works offline. Add `-cominavi-demo-data-remote` to make a Debug or Staging build download them instead, as an App Review build does.

Use the `-cominavi-demo-data` launch argument to start directly in Demo data during automated testing. Use `-cominavi-circlems-data` when an authenticated integration test must ignore the persisted choice. A user can also choose Demo data on the login screen or switch data sources from Profile.
