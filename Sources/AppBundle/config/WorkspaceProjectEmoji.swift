import Foundation

/// Swift Characters keep flags, skin tones and joined emoji together as one glyph.
func normalizedWorkspaceProjectEmoji(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count == 1 else { return nil }
    let scalars = value.unicodeScalars
    // Digits/#/* become emoji only as complete keycaps, not merely with VS16.
    if let first = scalars.first, first.value < 0x80, !scalars.contains(where: { $0.value == 0x20E3 }) {
        return nil
    }
    if scalars.count == 1, scalars.first?.properties.isEmojiModifier == true { return nil }
    if scalars.count == 1, let scalar = scalars.first, (0x1F1E6...0x1F1FF).contains(scalar.value) { return nil }
    let hasEmoji = scalars.contains { $0.properties.isEmoji }
    let hasPresentation = scalars.contains {
        $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3
    }
    return hasEmoji && hasPresentation ? value : nil
}
