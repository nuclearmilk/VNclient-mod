# VNclient-mod

[中文](./README.md)

A third-party Flutter client for [VNDB](https://vndb.org/) (Visual Novel Database), maintained and customized based on [sunxibing114514/VNclient](https://github.com/sunxibing114514/VNclient), featuring a modern Material Design 3 interface with enhanced localization and usability improvements.

> Note: Parts of this codebase were generated and refactored with AI assistance.

---

## ✨ Features

### 1. Visual Novel Details & Browsing
- **Comprehensive VN Information**: Developers, publishers, relations, tags (with category & spoiler level filters), characters, collapsible staff credits by role, releases, screenshots, and external links.
- **Human-First Description Translation**: Prioritizes community human translations from `vndbtran` when translating VN descriptions, automatically falling back to MyMemory machine translation with source attribution.
- **Bayesian Ratings & Direct Voting**: Displays official Bayesian rating, rank, and vote distribution. Logged-in users can view their current score, submit, update, or revoke votes directly from the detail page.
- **Browsing History**: Automatically records recently viewed VNs locally with swipe-to-delete and one-tap clear.

### 2. Character, Voice Actor & Producer Enhancements
- **Japanese-First Name Display**:
  - Character detail pages prioritize Japanese original names as the primary title and English/romaji as the subtitle, supporting long-press to copy for both.
  - Voice actor (seiyuu) labels prioritize Japanese names to keep layouts clean and link directly to the staff detail page.
  - Staff/seiyuu detail pages use Japanese names as primary titles and order works, songs, and voiced roles by language priority.
- **Inline Producer Works**: Browse all VNs by a producer with inline pagination directly on the producer detail page without jumping to an external webpage.
- **Producer Follows & New Release Alerts**: Follow favorite producers and receive in-app notifications when new works are added.

### 3. Tag / Trait & UI Localization
- **~400 Community-Translated Tags & Traits**: Built-in Chinese terminology dictionary for common VNDB tags and character traits across badges, list pages, detail pages, and search results.
- **Multi-Language UI & Title Preference**: Supports **Simplified Chinese / English / Japanese** UI switching, plus a toggle between **Romaji** and **Japanese/Original** VN titles.

### 4. Search & Discovery
- **7-Target Unified Search**: Switch seamlessly between **VNs, Characters, Producers, Staff, Releases, Tags, and Traits**.
- **Advanced Filters for VNs & Characters**: Filter VNs by language, platform, release year, minimum rating, tag, and developer; filter characters by role, blood type, sex/gender, cup size, body measurements, birthday month, trait, voice actor, and VN.
- **Refined Search Bar UI**: Quick toggle for advanced filters on the left of the search field, and an auto-hiding clear (`×`) button on the right that only appears when text is entered.
- **Configurable Random VN**: Draw random VNs filtered by language, platform, tags, rating, release year, R18 status, freeware status, and engine.

### 5. Home Layout & User List Management
- **Streamlined Home Page**: Places Site & Community navigation and logged-in user tools at the top, followed by Recent Changes, Personalized Recommendations, Today's Birthdays, Just Released, Upcoming Releases, Database Stats, and random quotes.
- **Live List Counts**: Displays real-time VN counts on every tab in "My List" (including "All", standard status tabs, and custom user labels).
- **Standardized Date Picker**: Uses Flutter's native date picker (`YYYY-MM-DD`) for start and finish dates when editing list entries.

### 6. Theming & Updates
- **Material Design 3 & Custom Wallpapers**: Supports light/dark/system themes, built-in VN wallpapers, and **custom local background images** with full support for custom accent color overrides.
- **Dynamic Version Metadata**: Reads app version directly from package metadata (`package_info_plus`) and supports checking for updates via GitHub Releases.

---

## 🚀 Getting Started

### Prerequisites

- Flutter SDK `>= 3.0.0 < 4.0.0`
- Android SDK / JDK 17 (for Android builds)
- A VNDB account (for user list and voting features)

### Installation & Build

```bash
# Clone the repository
git clone https://github.com/nuclearmilk/VNclient-mod.git
cd VNclient-mod

# Install dependencies
flutter pub get

# Build universal release APK
flutter build apk --release

# Or build split-per-ABI APKs
flutter build apk --release --split-per-abi
```

---

## 📄 License

Licensed under the [Apache-2.0 License](./LICENSE).
