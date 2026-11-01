import Foundation

extension OpenPush {
    struct IamPersistedState: Codable, Sendable {
        struct Redisplay: Codable, Sendable {
            var lastDisplayTime: Double
            var displayQuantity: Int
        }
        var dismissed: Set<String> = []
        var impressioned: Set<String> = []
        /// The click ids already reported, kept per message: a message that is
        /// shown again is a new chance to click the same block, so its ids are
        /// cleared with the display rather than remembered for the install.
        var clickedByMessage: [String: Set<String>] = [:]
        /// The messages whose first click has been reported. This one is for
        /// the life of the install: a first click happens once.
        var firstClicked: Set<String> = []
        /// The carousel pages already reported, keyed `"<messageId>|<pageId>"`.
        /// Swiping back to a card is not a new page impression, so a page is
        /// counted once per display; a message with redisplay budget has its
        /// pages cleared with the display, exactly as its click ids are.
        var pageImpressions: Set<String> = []
        var redisplay: [String: Redisplay] = [:]
        var lastTimeInAppDismissed: Double?
    }
}

extension OpenPush.IamPersistedState {
    /// Where the flat click ids of a blob written before clicks were tracked
    /// per message are parked on the way in. Nothing ever reads them: a click
    /// id is stable across displays, so honoring them would silence a
    /// redisplayed message's clicks forever. Nothing writes them back either —
    /// `encode(to:)` never writes that key — and the first restore purge drops
    /// the bucket, because `_legacy` is not a message the engine knows.
    static let legacyClickBucket = "_legacy"

    private enum CodingKeys: String, CodingKey {
        case dismissed, impressioned, clickedByMessage, firstClicked
        case pageImpressions, redisplay, lastTimeInAppDismissed
        case clickedClickIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        dismissed = try container.decodeIfPresent(Set<String>.self, forKey: .dismissed) ?? []
        impressioned = try container.decodeIfPresent(Set<String>.self, forKey: .impressioned) ?? []
        clickedByMessage = try container.decodeIfPresent([String: Set<String>].self,
                                                         forKey: .clickedByMessage) ?? [:]
        firstClicked = try container.decodeIfPresent(Set<String>.self, forKey: .firstClicked) ?? []
        pageImpressions = try container.decodeIfPresent(Set<String>.self,
                                                        forKey: .pageImpressions) ?? []
        redisplay = try container.decodeIfPresent([String: Redisplay].self, forKey: .redisplay) ?? [:]
        lastTimeInAppDismissed = try container.decodeIfPresent(Double.self,
                                                               forKey: .lastTimeInAppDismissed)
        if let legacy = try container.decodeIfPresent(Set<String>.self, forKey: .clickedClickIds),
           !legacy.isEmpty {
            clickedByMessage[Self.legacyClickBucket, default: []].formUnion(legacy)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dismissed, forKey: .dismissed)
        try container.encode(impressioned, forKey: .impressioned)
        try container.encode(clickedByMessage, forKey: .clickedByMessage)
        try container.encode(firstClicked, forKey: .firstClicked)
        try container.encode(pageImpressions, forKey: .pageImpressions)
        try container.encode(redisplay, forKey: .redisplay)
        try container.encodeIfPresent(lastTimeInAppDismissed, forKey: .lastTimeInAppDismissed)
    }
}

extension OpenPush {
    struct IamMessage: Sendable {
        let id: String
        let htmlPath: String
        let layout: String
        let groups: [[IamCondition]]
        let displayDuration: Double?
        let redisplayLimit: Int
        let redisplayDelay: Double
        /// Epoch seconds after which the campaign is over. `nil` means it runs
        /// until the server stops returning it.
        let endTime: Double?
    }
}
