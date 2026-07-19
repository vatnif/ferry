import Foundation

/// The bundled-dependency license notices shown in the Acknowledgements window
/// (M16 checkpoint C, ADR-028). Pure and headless-testable: the list, the
/// per-dependency copyright lines, and the full license bodies live here so the
/// app's SwiftUI view only renders them — and a unit test can pin the list
/// against `docs/LICENSING.md` (every shipped dependency must appear, and every
/// license must be one the commercial-redistribution policy allows, CLAUDE.md
/// rule 4).
///
/// This mirrors LICENSING.md's "Current dependency inventory": update BOTH when
/// `Package.swift` or the pinned versions change.

/// A license under which a bundled dependency ships. `rawValue` is the
/// short SPDX-style label shown in the UI; `body` is the reproducible notice
/// text (MIT/Apache-2.0 obligations, LICENSING.md).
public enum DependencyLicense: String, Sendable, CaseIterable {
    case mit = "MIT"
    case apache2 = "Apache-2.0"
    case curl = "curl (MIT/X derivative)"
    case appleSDK = "Apple SDK License Agreement"

    /// True for the licenses Ferry's policy permits for a closed-source
    /// commercial product (CLAUDE.md rule 4). Every acknowledgement's license
    /// must satisfy this — pinned by `AcknowledgementsTests`.
    public var isCommerciallyRedistributable: Bool {
        switch self {
        case .mit, .apache2, .curl, .appleSDK: return true
        }
    }

    /// The reproducible license body. MIT/curl obligations are met by
    /// reproducing the copyright + permission notice; Apache-2.0 by reproducing
    /// the standard notice and pointing at the full text (the per-dependency
    /// copyright is carried on the `Acknowledgement`).
    public var body: String {
        switch self {
        case .mit:
            return """
            Permission is hereby granted, free of charge, to any person obtaining a \
            copy of this software and associated documentation files (the “Software”), \
            to deal in the Software without restriction, including without limitation \
            the rights to use, copy, modify, merge, publish, distribute, sublicense, \
            and/or sell copies of the Software, and to permit persons to whom the \
            Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in \
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING \
            FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER \
            DEALINGS IN THE SOFTWARE.
            """
        case .apache2:
            return """
            Licensed under the Apache License, Version 2.0 (the “License”); you may not \
            use these files except in compliance with the License. You may obtain a \
            copy of the License at:

                https://www.apache.org/licenses/LICENSE-2.0

            Unless required by applicable law or agreed to in writing, software \
            distributed under the License is distributed on an “AS IS” BASIS, WITHOUT \
            WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the \
            License for the specific language governing permissions and limitations \
            under the License.
            """
        case .curl:
            return """
            Permission to use, copy, modify, and distribute this software for any \
            purpose with or without fee is hereby granted, provided that the above \
            copyright notice and this permission notice appear in all copies.

            THE SOFTWARE IS PROVIDED “AS IS” AND THE AUTHOR DISCLAIMS ALL WARRANTIES \
            WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF \
            MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY \
            SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES \
            WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN \
            ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR \
            IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
            """
        case .appleSDK:
            return """
            Portions of this software are provided by Apple Inc. as part of the macOS \
            SDK (SwiftUI, Foundation, Security, AppKit, and related frameworks), used \
            under the Apple SDK License Agreement. These frameworks ship with macOS and \
            are not redistributed by Ferry.
            """
        }
    }
}

/// One bundled dependency's notice.
public struct Acknowledgement: Identifiable, Sendable, Hashable {
    public var id: String { name }
    /// Display name (matches LICENSING.md).
    public let name: String
    /// What Ferry uses it for.
    public let purpose: String
    /// The reproduced copyright line (MIT/BSD/Apache-2.0 obligation).
    public let copyright: String
    public let license: DependencyLicense

    public init(name: String, purpose: String, copyright: String, license: DependencyLicense) {
        self.name = name
        self.purpose = purpose
        self.copyright = copyright
        self.license = license
    }
}

public enum Acknowledgements {
    /// The full acknowledgements list, in display order (Ferry's own frameworks
    /// first, then the SSH/crypto stack, then the terminal + FTP backends).
    /// Mirrors LICENSING.md → "Current dependency inventory" (incl. the
    /// transitive Apache-2.0 / MIT graph pulled in by Citadel).
    public static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "Apple SDKs",
            purpose: "SwiftUI, Foundation, Security, AppKit and related system frameworks.",
            copyright: "Copyright © Apple Inc. All rights reserved.",
            license: .appleSDK),
        Acknowledgement(
            name: "Citadel",
            purpose: "SSH and SFTP client (the SFTP, SCP, tunnel and terminal backends).",
            copyright: "Copyright © Joannis Orlandos and the Citadel project authors.",
            license: .mit),
        Acknowledgement(
            name: "swift-nio-ssh",
            purpose: "SSH transport that Citadel rides on (provides the remote-forward API).",
            copyright: "Copyright © the SwiftNIO SSH project authors.",
            license: .apache2),
        Acknowledgement(
            name: "swift-crypto",
            purpose: "Host-key SHA-256 fingerprints and private-key parsing.",
            copyright: "Copyright © Apple Inc. and the SwiftCrypto project authors.",
            license: .apache2),
        Acknowledgement(
            name: "SwiftNIO",
            purpose: "Asynchronous networking that the SSH stack and tunnels are built on.",
            copyright: "Copyright © the SwiftNIO project authors.",
            license: .apache2),
        Acknowledgement(
            name: "swift-atomics",
            purpose: "Low-level atomics used by SwiftNIO.",
            copyright: "Copyright © Apple Inc. and the Swift project authors.",
            license: .apache2),
        Acknowledgement(
            name: "swift-collections",
            purpose: "Additional data structures used by the SSH stack.",
            copyright: "Copyright © Apple Inc. and the Swift project authors.",
            license: .apache2),
        Acknowledgement(
            name: "swift-log",
            purpose: "Logging API used by the SSH stack.",
            copyright: "Copyright © Apple Inc. and the SwiftLog project authors.",
            license: .apache2),
        Acknowledgement(
            name: "BigInt",
            purpose: "Big-integer arithmetic for RSA key math (via Citadel).",
            copyright: "Copyright © Károly Lőrentey.",
            license: .mit),
        Acknowledgement(
            name: "SwiftTerm",
            purpose: "Terminal emulator behind the built-in terminal.",
            copyright: "Copyright © Miguel de Icaza and the SwiftTerm project authors.",
            license: .mit),
        Acknowledgement(
            name: "libcurl",
            purpose: "FTP and FTPS transfers (the system library that ships with macOS).",
            copyright: "Copyright © Daniel Stenberg and many contributors.",
            license: .curl)
    ]
}
