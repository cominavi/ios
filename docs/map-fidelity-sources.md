# Map fidelity sources

Last checked: 2026-07-23.

The map deliberately separates permanent venue/OSM data from event-specific
Comic Market operations. Event operations must not be carried forward to a new
Comiket without re-checking the organizer map.

## C108 operations

- [C108 International Participants](https://www.comiket.co.jp/info-a/TAFO/C108TAFO/index.html): official hall use and the current ground truth that East Halls 4–6—not East 1–3—are closed for construction.
- [Tokyo Big Sight East 4–6 construction-period safety map](https://www.bigsight.jp/organizer/download/pdf/risk_manual_construction_east_4-6.pdf): venue-owner confirmation that East 4–6 are closed from March 30 through December 31, 2026.
- [C108 placement-team note](https://www.comiket.co.jp/info-c/C108/C108hitokoto/HAICH.html): explicitly states that East 1–3 refurbishment finished last year and East 4–6 are now under construction.
- [C108 International Map](https://www.comiket.co.jp/info-a/TAFO/C108TAFO/C108_InternationalMap.pdf): entry/waiting areas, ticket exchange, information/international desks, first aid, cosplay areas, and event-day movement routes.
- [C108 Tickets](https://www.comiket.co.jp/info-a/TAFO/C108TAFO/ticket.html): Early/AM/PM entry times, eplus QR wristband exchange near the Rinkai Line station before 12:30 and at Entrance Plaza afterwards, and TFT West 2F cosplay early entry.
- [C108 Cosplay Information](https://www.comiket.co.jp/info-a/TAFO/C108TAFO/cosplay.html): East 8, gardens, rooftop, East 7 antenna-site areas, and changing rooms.
- [C108 Appeal Enclosure](https://www.comiket.co.jp/info-c/C108/C108AppealEnclosure.pdf): detailed East 1–3, East 7, West, and South operational plans.

The otherwise useful [Comiket beginner venue guide](https://harenohi.comiket.co.jp/index.php/beginnersguide/generals/guideonsite/)
still says East 1–3 are unavailable. That statement is stale and is deliberately
not used for C108 closure state because the dated venue-owner construction map,
C108 placement note, current C108 hall allocation, and current international
map all agree on East 4–6.

ComiNavi deliberately does not render crowd-flow or pedestrian routes. A user
can pin a destination and copy its venue-aware address, but must follow current
signage and staff directions. The organizer warns that routes change with
congestion, and no authoritative source assigns a permanent up/down direction
to each East Hall stair or escalator.

Field reports were used only to model behavior, not to override an event's
official map:

- [Comitteru escalator safety report](https://comitteru.com/escalator/): staff remain at escalators and enforce standing still; this supports a staff-directed label but not a permanent direction.
- [Aniota Club venue strategy guide](https://aniotaclub.net/tokyobigsight-strategyguide/): the Galleria is the main East circulation spine, East 7–8 require extra travel time, and hall use changes by event.
- [Webcosmedia C106 cosplay field report](https://webcosmedia.jp/10834/): observed 14 minutes from the entrance to East 8 and a 19-minute rooftop escalator queue, confirming that short geometric paths can become slow bottlenecks.
- [JR East route guide](https://media.jreast.co.jp/articles/3391): Kokusai-tenjijo is about a seven-minute walk, with the station-front Lawson as a visible route landmark.

## Permanent venue context

- [Tokyo Big Sight East Exhibition Halls](https://www.bigsight.jp/english/organizer/facilities/east.html): building layout and the two-level Galleria.
- [Tokyo Big Sight floor map](https://www.bigsight.jp/english/download/pdf/bigsight_map_color_e.pdf): elevators, escalators, stairs, toilets, first aid, and permanent facilities.
- [Tokyo Big Sight shops and restaurants](https://www.bigsight.jp/english/visitor/shop/): current on-campus convenience stores, food, and service locations.
- [Tokyo Big Sight accessibility](https://www.bigsight.jp/english/visitor/services/accessibility.html): accessible toilets, elevators, and information counters.

## OpenStreetMap snapshot

Nearby stations, stores, ATMs, pharmacy, toilets, and pedestrian ways were
queried from OpenStreetMap via Overpass on 2026-07-22. Important anchors include
Tokyo Big Sight Station (node 3349961080), Kokusai-tenjijo Station (node
6214783969), Lawson station-front (node 2298236533), and the curated footway /
steps geometry stored in `BigSightPedestrianWays.geojson`.

These POIs should be refreshed before a release when opening hours or tenants
matter; the app currently presents location, not a promise that a shop is open.
