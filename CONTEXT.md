# GlobeFlip

GlobeFlip is a macOS utility concerned only with interpreting the Globe/Fn key and moving between the user's enabled keyboard input sources.

## Language

**Input Source**:
A keyboard layout or input method enabled by the user in macOS.
_Avoid_: Language

**Active Input Source**:
The input source currently receiving typed keyboard input.
_Avoid_: Current language

**Switching Cycle**:
The ordered set of enabled input sources through which a Globe Tap advances.
_Avoid_: Language pair

**Globe Tap**:
A completed press and release of Globe/Fn without another key joining the gesture and before it becomes an Fn Hold.
_Avoid_: Language shortcut

**Fn Hold**:
A Globe/Fn gesture intended to preserve the keyboard's native Fn behavior, either through sustained pressure or use with another key.
_Avoid_: Long Globe Tap

**Menu Bar Utility**:
A background macOS application controlled from the menu bar and a settings window, without a Dock presence.
_Avoid_: Dock app, mini-bar app
