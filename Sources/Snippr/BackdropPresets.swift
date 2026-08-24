import AppKit
import Foundation

// MARK: - Named backdrop presets (WP7)
//
// A preset is a NAMED BackdropStyle — nothing more. It stores the same value
// type the panel edits and the compositor reads, so a preset cannot describe a
// backdrop the app is unable to draw.

/// Not `BackdropPreset`: that name belongs to the v0 five-case enum, which is
/// still the migration key and the overlay's payload.
struct BackdropNamedPreset: Codable, Equatable, Hashable {
    var name: String
    var style: BackdropStyle
}

/// Presets live in one JSON blob under one key rather than a key per field:
/// a half-written preset would otherwise survive as a mix of two.
enum BackdropPresetStore {
    static let maxPresets = 24
    static let maxNameLength = 40

    static func load() -> [BackdropNamedPreset] {
        guard let data = Settings.shared.backdropPresetData,
              let list = try? JSONDecoder().decode(
                [BackdropNamedPreset].self, from: data)
        else { return [] }
        // Clamp on the way OUT as well: a blob written by a newer build, or
        // hand-edited in defaults, must not hand the panel a style the
        // compositor would reject.
        return list.map { BackdropNamedPreset(name: $0.name, style: $0.style.clamped()) }
    }

    private static func save(_ list: [BackdropNamedPreset]) {
        Settings.shared.backdropPresetData = try? JSONEncoder().encode(list)
    }

    /// Returns nil when the name is empty, already taken, or the list is full.
    /// The caller reports; this does not silently rename or overwrite.
    @discardableResult
    static func add(name: String, style: BackdropStyle) -> [BackdropNamedPreset]? {
        let trimmed = normalized(name)
        guard !trimmed.isEmpty else { return nil }
        var list = load()
        guard list.count < maxPresets else { return nil }
        guard !list.contains(where: { sameName($0.name, trimmed) }) else {
            return nil
        }
        list.append(BackdropNamedPreset(name: trimmed, style: style.clamped()))
        save(list)
        return list
    }

    @discardableResult
    static func rename(from old: String, to new: String) -> [BackdropNamedPreset]? {
        let trimmed = normalized(new)
        guard !trimmed.isEmpty else { return nil }
        var list = load()
        guard let index = list.firstIndex(where: { sameName($0.name, old) })
        else { return nil }
        // Renaming to the same name, in a different case, is a rename — not a
        // collision with itself.
        if list.enumerated().contains(where: {
            $0.offset != index && sameName($0.element.name, trimmed)
        }) { return nil }
        list[index].name = trimmed
        save(list)
        // The auto-apply choice is stored BY NAME, so it follows the rename or
        // it would quietly stop applying anything.
        if let chosen = Settings.shared.backdropAutoApplyPreset,
           sameName(chosen, old) {
            Settings.shared.backdropAutoApplyPreset = trimmed
        }
        return list
    }

    @discardableResult
    static func remove(name: String) -> [BackdropNamedPreset]? {
        var list = load()
        guard let index = list.firstIndex(where: { sameName($0.name, name) })
        else { return nil }
        list.remove(at: index)
        save(list)
        // Deleting the preset every capture was using turns auto-apply off
        // rather than leaving it pointing at nothing.
        if let chosen = Settings.shared.backdropAutoApplyPreset,
           sameName(chosen, name) {
            Settings.shared.backdropAutoApplyPreset = nil
        }
        return list
    }

    static func style(named name: String) -> BackdropStyle? {
        load().first { sameName($0.name, name) }?.style
    }

    /// The style a fresh capture should wear, or nil when the user has not
    /// asked for one. Both the editor path and the copy/save path read THIS,
    /// so a capture cannot be framed on one route and bare on the other.
    static var autoApplyStyle: BackdropStyle? {
        guard Settings.shared.backdropAutoApplyEnabled,
              let name = Settings.shared.backdropAutoApplyPreset,
              let style = style(named: name),
              style.kind != .none
        else { return nil }
        return style
    }

    static func normalized(_ name: String) -> String {
        String(
            name.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxNameLength))
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    static func removeAllForTesting() {
        Settings.shared.backdropPresetData = nil
        Settings.shared.backdropAutoApplyEnabled = false
        Settings.shared.backdropAutoApplyPreset = nil
    }
}
