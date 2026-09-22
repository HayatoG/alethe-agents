# Changelog

All notable user-facing changes to Alethe for macOS (native) are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Native macOS app skeleton (Swift, macOS 26+), bundle id `com.kc1t.alethe.mac`.
- Main window with a sidebar and toolbar, a Settings window (⌘,) and UI zoom in the View menu
  (⌘+ / ⌘− / ⌘0); the zoom level and sidebar visibility are restored on relaunch.
- Data is stored per profile in `~/Library/Application Support/com.kc1t.alethe.mac`.
