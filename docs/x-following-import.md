# X following import

The profile screen can import the basic public metadata for accounts followed by an X username and match those accounts to the currently installed Circle.ms catalog.

## Privacy and authentication boundary

1. The user authenticates with a supported provider and the backend issues a
   ComiNavi access/refresh session. Circle.ms provider tokens remain on the
   backend and are not sent through the app's import request.
2. The app sends its ComiNavi bearer access token to the X-following import
   endpoint. On `401`, it refreshes the ComiNavi session once and retries.
3. The streaming endpoint returns progress events followed by the X-following
   snapshot: stable X user ID, username, display name, canonical profile URL,
   and optional avatar URL.
4. Circle URLs, catalog rows, matches, imported-circle history, and favorite
   choices remain on the device.

The TwitterAPI.io key and the ComiNavi JWT signing secret must never be compiled into the app.

## Cache behavior

- Imports start only when the user opens the X-following import screen and taps the import button. The app does not schedule the next import or retry one automatically.
- Both the server and app enforce a six-hour interval between successful user-requested imports. The server remains authoritative after reinstall or local data loss; a failed attempt does not advance the cooldown.
- A failed request does not alter the last successful local import.
- Each successful import is merged into the local list by stable Circle.ms public circle ID. Circles missing from a later snapshot are retained.
- The X account that produced each match is retained as provenance.
- Stored public IDs are resolved against the currently installed catalog on every load; catalog-local row IDs are not persisted as identity.

## Favorites

The import page has one horizontal favorite-color row. A user can favorite a single imported circle group or all imported circles with one tap. An A+B group writes both Circle.ms favorites while remaining one visual circle.
