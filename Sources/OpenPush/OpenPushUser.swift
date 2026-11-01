import Foundation

public extension OpenPush {
    enum User {
        /// Set one tag. Tags are session state on the SDK side and are sent with
        /// this and every later registration; the server merges them.
        public static func addTag(key: String, value: String) {
            addTags([key: value])
        }

        /// Set several tags; nearby writes share one registration.
        ///
        /// A key or value the server will refuse is dropped here, one log line per
        /// key naming the rule it broke, rather than travelling and failing the
        /// whole registration — one malformed tag must not cost the app the other
        /// tags, the identity, and the token in the same body. An empty *value* is
        /// not malformed: that is `removeTag`'s deletion signal.
        public static func addTags(_ tags: [String: String]) {
            applyTags(tags, deleting: false)
        }

        /// The one merge path. `deleting` is the only caller allowed to stage a key
        /// the shape rules refuse: an install from an earlier SDK build could have put
        /// such a key on the server, and the tombstone is the only way to clean it
        /// up — refusing that too would strand the key there for good.
        private static func applyTags(_ tags: [String: String], deleting: Bool) {
            guard !tags.isEmpty else { return }
            var accepted: [String: String] = [:]
            for (key, value) in tags {
                guard !key.isEmpty else {
                    OpenPush.onLog("✗ tag dropped — a tag key cannot be empty")
                    continue
                }
                if !deleting {
                    guard key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                        OpenPush.onLog("✗ tag '\(key)' dropped — a tag key cannot contain " +
                                       "whitespace")
                        continue
                    }
                    guard key.count <= OpenPush.tagKeyLimit else {
                        OpenPush.onLog("✗ tag '\(key)' dropped — a tag key can be at most " +
                                       "\(OpenPush.tagKeyLimit) characters; this one is " +
                                       "\(key.count)")
                        continue
                    }
                }
                guard value.count <= OpenPush.tagValueLimit else {
                    OpenPush.onLog("✗ tag '\(key)' dropped — a tag value can be at most " +
                                   "\(OpenPush.tagValueLimit) characters; this one is " +
                                   "\(value.count)")
                    continue
                }
                accepted[key] = value
            }
            guard !accepted.isEmpty else { return }
            let merged = OpenPush.state.mergeTags(accepted)
            OpenPush.onLog("• tags updated (\(merged.count) held): " +
                           accepted.keys.sorted().joined(separator: ", "))
            OpenPush.coalesceWrite(heldNote: "tags")
        }

        /// Delete one tag. The key stays in the body with an empty value: that is
        /// the server's delete signal, and omitting the key would leave the old
        /// value in place.
        public static func removeTag(_ key: String) {
            applyTags([key: ""], deleting: true)
        }

        /// The tags this user holds. A deletion that has not reached the server yet
        /// is still in the body as an empty value, but it is not a tag any more, so
        /// it is not reported here.
        public static func getTags() -> [String: String] {
            OpenPush.state.tagMap.filter { !$0.value.isEmpty }
        }

        /// Delete several tags in one coalesced write.
        public static func removeTags(_ keys: [String]) {
            let deletions = keys.reduce(into: [String: String]()) { result, key in
                guard !key.isEmpty else { return }
                result[key] = ""
            }
            guard !deletions.isEmpty else { return }
            applyTags(deletions, deleting: true)
        }
    }
}

public extension OpenPush.User {
    /// A live accessor: values are computed when read, not captured here.
    static var pushSubscription: OpenPush.PushSubscription {
        OpenPush.PushSubscription()
    }

    /// The identified external ID, or nil for anonymous and detached installs.
    static var externalId: String? {
        if case .identified(let externalID, _) = OpenPush.state.currentIdentity {
            return externalID
        }
        return nil
    }
}

extension OpenPush {
    /// The server keeps at most ten alias labels per user. Exceeding it is a
    /// loud log, not a client-side truncation.
    static let aliasLimit = 10
    /// What the server accepts for a tag. Longer keys and values are refused
    /// there, so they are refused here, where the app can still see why.
    static let tagKeyLimit = 60
    static let tagValueLimit = 300
    /// `external_id` belongs to login/logout and is the claim identity
    /// verification checks. It is never an alias label.
    static let reservedAliasLabel = "external_id"
}

public extension OpenPush.User {
    /// Add one alias — an additional lookup label for this user, such as a
    /// studio's own player id alongside `external_id`. Aliases are for lookup and
    /// targeting only: setting one never merges two users.
    static func addAlias(label: String, id: String) {
        addAliases([label: id])
    }

    /// Add several aliases; nearby writes share one registration.
    static func addAliases(_ aliases: [String: String]) {
        applyAliases(aliases, deleting: false)
    }

    /// The one merge path. `deleting` is the only caller allowed to stage the empty
    /// id that is S3's delete signal; through `addAliases` an empty id is a typo.
    private static func applyAliases(_ aliases: [String: String], deleting: Bool) {
        guard !aliases.isEmpty else { return }
        var accepted: [String: String] = [:]
        for (label, id) in aliases {
            guard !label.isEmpty else {
                OpenPush.onLog("✗ alias dropped — an alias label cannot be empty")
                continue
            }
            guard label != OpenPush.reservedAliasLabel else {
                OpenPush.onLog("✗ alias '\(OpenPush.reservedAliasLabel)' refused — that field " +
                               "belongs to login/logout and is the claim identity " +
                               "verification checks")
                continue
            }
            guard deleting || !id.isEmpty else {
                OpenPush.onLog("✗ alias '\(label)' dropped — an alias id cannot be empty; " +
                               "use removeAlias")
                continue
            }
            accepted[label] = id
        }
        guard !accepted.isEmpty else { return }
        let merged = OpenPush.state.mergeAliases(accepted)
        OpenPush.onLog("• aliases updated (\(merged.count) held): " +
                       accepted.keys.sorted().joined(separator: ", "))
        // A staged deletion is a label on its way out, not one of the labels the
        // server has to keep room for.
        let labelsHeld = merged.filter { !$0.value.isEmpty }.count
        if labelsHeld > OpenPush.aliasLimit {
            OpenPush.onLog("• \(labelsHeld) alias labels are held, but the server keeps at " +
                           "most \(OpenPush.aliasLimit) per user — the extra labels will not " +
                           "be applied")
        }
        OpenPush.coalesceWrite(heldNote: "aliases")
    }

    /// Delete one alias. The label stays in the body with an empty value — S3's
    /// delete signal, the same convention as `removeTag` and `logout`.
    static func removeAlias(_ label: String) {
        applyAliases([label: ""], deleting: true)
    }

    /// Delete several aliases in one coalesced write.
    static func removeAliases(_ labels: [String]) {
        let deletions = labels.reduce(into: [String: String]()) { result, label in
            guard !label.isEmpty else { return }
            result[label] = ""
        }
        guard !deletions.isEmpty else { return }
        applyAliases(deletions, deleting: true)
    }
}
