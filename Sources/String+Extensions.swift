import Foundation

extension String {
    var normalizedMusicUrl: String {
        self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
