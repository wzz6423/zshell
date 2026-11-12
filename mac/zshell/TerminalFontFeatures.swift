import AppKit
import CoreText

struct TerminalFontFeatures: Equatable {
    struct Feature: Equatable {
        let tag: String
        let value: UInt32

        var ghosttyValue: String {
            switch value {
            case 0: "-\(tag)"
            case 1: tag
            default: "\(tag)=\(value)"
            }
        }
    }

    private static let ligatureTags = ["calt", "liga", "clig", "dlig", "hlig"]
    let features: [Feature]

    init(_ text: String = "", ligatures: Bool = true) {
        var features = Self.parse(text) ?? []
        if !ligatures {
            // Required script shaping remains enabled; this switch controls
            // optional programming and typographic ligatures.
            features.removeAll { Self.ligatureTags.contains($0.tag) }
            features += Self.ligatureTags.map { Feature(tag: $0, value: 0) }
        }
        self.features = features
    }

    static func parse(_ text: String) -> [Feature]? {
        guard text.utf8.count <= 4096 else { return nil }
        let tokens = text.split { $0 == "," || $0.isWhitespace }
        guard tokens.count <= 64 else { return nil }
        var result: [Feature] = []
        for token in tokens {
            var name = token
            var value: UInt32 = 1
            if name.first == "-" || name.first == "+" {
                value = name.first == "-" ? 0 : 1
                name = name.dropFirst()
                guard !name.contains("=") else { return nil }
            } else if let separator = name.firstIndex(of: "=") {
                guard let number = UInt32(name[name.index(after: separator)...]) else { return nil }
                value = number
                name = name[..<separator]
            }
            guard name.utf8.count == 4,
                  name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
            else { return nil }
            let tag = String(name)
            result.removeAll { $0.tag == tag }
            result.append(Feature(tag: tag, value: value))
        }
        return result
    }

    func applying(to font: NSFont) -> NSFont {
        guard !features.isEmpty else { return font }
        let settings: [[String: Any]] = features.map {
            [kCTFontOpenTypeFeatureTag as String: $0.tag,
             kCTFontOpenTypeFeatureValue as String: NSNumber(value: $0.value)]
        }
        var attributes: [NSFontDescriptor.AttributeName: Any] = [.featureSettings: settings]
        if let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] {
            attributes[.cascadeList] = cascade.map { $0.addingAttributes([.featureSettings: settings]) }
        }
        let descriptor = font.fontDescriptor.addingAttributes(attributes)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
