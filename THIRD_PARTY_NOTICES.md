# Third-party notices

Provider usage parsing in `Sources/TokenSpenderCore/DirectSources.swift`, including the Kimi Code usage mapping, is adapted from [CodexBar](https://github.com/steipete/CodexBar). `Sources/TokenSpenderCore/NativeClaude.swift` also adapts its Claude OAuth credential/window parsing, profile-path conventions, request headers, and legacy Keychain interaction control, from `ClaudeOAuthCredentialModels.swift`, `ClaudeOAuthUsageFetcher.swift`, `ClaudeConfigPaths.swift`, and `KeychainSecurity.swift`. Its license follows.

## CodexBar — MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Runtime integration

[claude-swap](https://github.com/realiti4/claude-swap) is an optional, separately installed integration invoked for configured managed Claude accounts; a native single Claude Code login does not require it. It is not bundled. Provider names and referenced products belong to their respective owners; this project is not endorsed by them.
