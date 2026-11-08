# Glossary

English is the source language of the app. Every user-visible string is an
English key in `ComiNavi/Localizable.xcstrings` (or `ImageCache.xcstrings`), and
Japanese, Korean, and Chinese are translations. `scripts/check-xcstrings.sh`
rejects Japanese keys and Japanese Swift literals, so new copy starts in English.

Use the terms below in English copy and keep the listed translations. When a
term is missing, copy the nearest existing translation from the catalog instead
of inventing a new one.

## Names

| English | Use | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- |
| Comiket | Short event name in all UI copy ("C108", "Choose another Comiket"). | コミケ | 코미케 / Comiket | Comiket | Comiket |
| Comic Market | Formal name only: legal text, the disclaimer, the official catalog. | コミックマーケット | Comic Market | Comic Market | Comic Market |
| C108 | Event number. Always `C` + number, never translated. | C108 | C108 | C108 | C108 |
| Circle.ms | The official catalog service and sign-in provider. Keep the casing. | Circle.ms | Circle.ms | Circle.ms | Circle.ms |
| Tokyo Big Sight | Venue name. The Chinese catalogs keep it in Latin letters. | 東京ビッグサイト | 도쿄 빅사이트 | Tokyo Big Sight | Tokyo Big Sight |
| ComiNavi | App name. Never translated. | ComiNavi | ComiNavi | ComiNavi | ComiNavi |

## Accounts

| English | Notes | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- |
| Sign in / Sign In | The action. Use "Sign In" only as a title-case button title. Never "Log in" or "Login". | ログイン | 로그인 | 登录 | 登入 |
| Sign out / Sign Out | The action. Never "Log out" in new copy. | ログアウト | 로그아웃 | 退出登录 / 注销 | 登出 |
| Signed in / Not signed in | Account state. | ログイン済み / ログインしていません | 로그인됨 / — | 已登录 / — | 已登入 / — |
| Link Circle.ms | Connect a Circle.ms account to ComiNavi. | Circle.msを連携 | — | — | — |

## Features

| English | Notes | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- |
| Map | Tab. | 地図 | 지도 | 地图 | 地圖 |
| Explore | Tab. | 探す | 탐색 | 探索 | 探索 |
| Shared Plans / Shared Plan | Tab and feature. A shopping list of circles that friends edit together. | 共有プラン | 공유 플랜 | 共享计划 | 共享計畫 |
| Plan | One shared plan. "Current plan", not "primary plan". | プラン | 플랜 | 计划 | 計畫 |
| Profile | Tab. | プロフィール | 프로필 | 我 | 我 |
| Toolbox | Event-day checklist, reminders, and official links. | お役立ち | 도구 모음 | 工具箱 | 工具箱 |
| Favorites / Favorite | Saved circles. | お気に入り | 즐겨찾기 | 收藏 | 收藏 |
| Circle | An exhibitor group. | サークル | 서클 | 社团 | 社團 |
| Catalog | The downloaded circle data for one Comiket. | カタログ | 카탈로그 | 目录 | 目錄 |
| Item list | A circle's list of items and prices. Do not use "Shinagaki" in English copy. | お品書き | 판매 목록 | 商品一览 | 商品一覽 |
| Circle cut | The circle's catalog image. Not "cover". | サークルカット | 서클 컷 | 社团图 | 社團圖 |

## Places

| English | Notes | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- |
| Space | A circle's table location, for example `East A01a`. Not "table" or "booth". | スペース | 부스 | 摊位 | 攤位 |
| Go to Space | Map action that finds a space by block and number. | スペースへ移動 | 부스로 이동 | 前往摊位 | 前往攤位 |
| Destination | A space pinned on the map. | 行き先 | 목적지 | 目的地 | 目的地 |
| East / West / South | Hall areas. | 東 / 西 / 南 | 동 / 서 / 남 | 东 / 西 / 南 | 東 / 西 / 南 |
| East 1–3, East 4–6 | Hall groups. Use an en dash. | 東1–3ホール | 동 1–3홀 | 东1–3馆 | 東1–3館 |
| Day 1 | Event day. | 1日目 | 1일차 | 第1天 | 第1天 |

Space codes such as `東A01a` stay in Japanese in data and in the "Japanese
address (for staff and signs)" row, because the venue signs use them.

## Style

- Write labels as plain verbs and nouns: "Show on map", "Go to Space", "Sign in".
- Do not use internal words in copy: "primary plan", "Shinagaki", "table location", "Local only".
- Chinese copy does not end with a full stop (。), and keeps the protected
  names in Latin letters (Tokyo Big Sight, Comic Market, Comiket, Cosplay).
- Keep the format placeholders of the key (`%@`, `%lld`) in every translation.
  Use positional placeholders (`%1$@`) when a translation changes the order.
