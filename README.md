# BattleLM-Hub

**BattleLM-Hub** is a macOS application that orchestrates multiple AI agents into a collaborative "Council" for enhanced decision-making and code review.

## Features

- 🤖 **Multi-Agent Collaboration** - Run multiple AI models (Claude, GPT, Gemini, etc.) simultaneously
- ⚔️ **AI Council Battles** - Let AI agents debate and evaluate each other's responses
- 🔥 **Dynamic Flame Aura** - Visual intensity indicators based on AI performance
- 📱 **iOS Companion Support** - Remote control via iOS app (separate app)
- 🔐 **Secure by Design** - All API keys stored locally, no cloud dependency

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/BattleLM-Hub.git
   ```

2. Open `BattleLM-Hub.xcodeproj` in Xcode

3. Build and run (⌘R)

## Architecture

```
BattleLM-Hub/
├── BattleLM/           # Main app source code
│   ├── App/            # App entry point
│   ├── Models/         # Data models
│   ├── Services/       # AI providers, networking
│   ├── ViewModels/     # Business logic
│   └── Views/          # SwiftUI views
├── BattleLMTests/      # Unit tests
├── BattleLMUITests/    # UI tests
├── Packages/           # Shared Swift packages
└── docs/               # Documentation
```

## Contributing

Contributions are welcome! Please read our contributing guidelines before submitting PRs.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - Terminal emulation
