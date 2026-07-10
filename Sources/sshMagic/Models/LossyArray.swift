import Foundation

/// Decodes a JSON array element-by-element, dropping entries that fail instead
/// of failing the whole array — used to salvage `hosts.json` when one bad entry
/// would otherwise discard every saved host.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else {
                // Decode (and discard) a value that always succeeds, purely to
                // advance the container past the bad entry. If even that fails
                // (container-level error), bail out rather than spin forever on
                // an index that can no longer advance.
                guard (try? container.decode(Skip.self)) != nil else { break }
            }
        }
        elements = decoded
    }

    /// Decodes successfully from ANY value without reading it.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
