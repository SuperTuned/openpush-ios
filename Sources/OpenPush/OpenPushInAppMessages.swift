import Foundation

public struct OpenPushInAppMessagesError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public extension OpenPush {
    struct InAppMessageLifecycleEvent: Sendable {
        /// The four moments of a presentation, in order. `willDisplay` is a
        /// request to show and `willDismiss` a request to take down; the `did`
        /// stages are facts about what the reader saw.
        public enum Stage: String, Sendable {
            case willDisplay, didDisplay, willDismiss, didDismiss
        }
        public let messageId: String
        public let stage: Stage
        /// The layout the server gave this message — `center`, `top`, `bottom`,
        /// `full` or `carousel`. It decides how the message is presented, and a
        /// host that logs or surfaces lifecycle events cannot otherwise see it.
        public let layout: String
        /// The stage as text, for hosts written against the string. It is a
        /// rendering of `stage`, never a second source of truth.
        public var phase: String { stage.rawValue }
    }

    struct InAppMessageClickEvent: Sendable {
        public let messageId: String
        public let actionId: String?
        public let url: String?
        public let urlTarget: String?
        public let closingMessage: Bool
        /// True only for the first click on this message, however many times
        /// it is shown — the same answer the receipt carries.
        public let firstClick: Bool
    }

    enum InAppMessages {
        public static var paused: Bool {
            get { IamEngine.shared.isPaused }
            set { IamEngine.shared.setPaused(newValue) }
        }

        public static func addTrigger(_ key: String, withValue value: Any) {
            IamEngine.shared.addTrigger(key, value: value)
        }
        public static func addTriggers(_ values: [String: Any]) {
            values.forEach { addTrigger($0.key, withValue: $0.value) }
        }
        public static func removeTrigger(_ key: String) { IamEngine.shared.removeTriggers([key]) }
        public static func removeTriggers(_ keys: [String]) { IamEngine.shared.removeTriggers(keys) }
        public static func clearTriggers() { IamEngine.shared.clearTriggers() }

        @discardableResult
        public static func addLifecycleListener(
            _ listener: @escaping @Sendable (InAppMessageLifecycleEvent) -> Void
        ) -> UUID { IamEngine.shared.addLifecycle(listener) }
        public static func removeLifecycleListener(_ handle: UUID) {
            IamEngine.shared.removeLifecycle(handle)
        }
        @discardableResult
        public static func addClickListener(
            _ listener: @escaping @Sendable (InAppMessageClickEvent) -> Void
        ) -> UUID { IamEngine.shared.addClick(listener) }
        public static func removeClickListener(_ handle: UUID) { IamEngine.shared.removeClick(handle) }

        static func onAppForegrounded() { IamEngine.shared.foregrounded() }
        static func onAppBackgrounded() { IamEngine.shared.backgrounded() }
        /// An accepted registration is what arms the first definition fetch.
        /// It is a second request through the host's transport, so a test that
        /// is about registration and counts what the transport saw turns it
        /// off; `IamEngine.resetForTests()` arms it again.
        static func onSubscriptionReady() {
            guard IamEngine.shared.fetchesOnSubscriptionReady else { return }
            IamEngine.shared.fetchIfSession(force: true)
        }
    }
}

extension OpenPush {
    final class IamEngine: @unchecked Sendable {
        static let shared = IamEngine()
        private let lock = NSLock()
        private var triggers: [String: IamTriggerValue] = [:]
        private var queue: [IamMessage] = []
        private var current: IamMessage?
        private var state = IamPersistedState()
        private var paused = false
        /// Gates exactly one thing: the fetch `onSubscriptionReady` starts when
        /// a registration is accepted. Nothing else reads it — a fetch reached
        /// any other way, including `fetchIfSession(force:)` and a trigger-driven
        /// re-evaluation, runs regardless. Only `setAutomaticFetchForTests(_:)`
        /// clears it, and `resetForTests()` puts it back to `true`.
        private var automaticFetchOnSubscriptionReady = true
        private var backgroundAt: Double?
        private var sessionStartedAt = Date().timeIntervalSince1970
        private var lastFetchAt: Double = 0
        private var triggerGeneration = 0
        private var displayedGeneration: [String: Int] = [:]
        private var lifecycle: [UUID: @Sendable (InAppMessageLifecycleEvent) -> Void] = [:]
        private var clicks: [UUID: @Sendable (InAppMessageClickEvent) -> Void] = [:]
        private var presenter: IamPresentation.Presenter = IamPresentation.system
        private var dismisser: IamPresentation.Dismisser = IamPresentation.systemDismiss
        private var now: @Sendable () -> Double = { Date().timeIntervalSince1970 }
        /// A document that could not be shown is skipped for the rest of the
        /// session, so a broken message cannot take the slot over and over.
        private var abandonedThisSession: Set<String> = []
        /// Every presentation gets its own token, so an event that arrives from
        /// a presentation that is over cannot speak for the one on screen —
        /// even when both show the same message.
        private var presentationToken = 0
        private var currentToken = 0
        private var fetchRetry: OpenPush.ScheduledWork?
        /// The token key everything this engine stores is filed under. It is
        /// handed in — by `attach`, and by every restore — and never fetched
        /// back out of `OpenPush.state`, because the only place it is needed is
        /// `persist()`, which runs under this engine's lock. Reading `State`
        /// from in there would nest `State`'s lock inside this one, which is the
        /// inversion half of a deadlock with `setup`, where the nesting runs the
        /// other way. `nil` until the first attach: an engine that has not been
        /// told which workspace it belongs to has nothing it may write.
        private var cachedTokenKey: String?
        /// The one pending wake-up for a message that is waiting only on the
        /// clock. At most one is outstanding: every re-evaluation replaces it.
        private var dynamicTimer: OpenPush.ScheduledWork?
        /// What the latest successful fetch returned. A message that is no
        /// longer in it has been deactivated server-side: it must not come back
        /// through the requeue path, and when it does come back it comes back
        /// with the fields the server sent last, not the ones it was shown with.
        /// `nil` means no fetch has landed yet; an empty set is a server that
        /// answered with nothing, which is a different thing entirely.
        private var knownIds: Set<String>?
        private var latestDefinitions: [String: IamMessage] = [:]
        /// True while a system permission prompt raised by a message's action
        /// is on screen. The queue stands still until the person answers it.
        private var awaitingPrompt = false
        /// The wake-up that releases the queue when no answer ever comes back.
        private var promptFallback: OpenPush.ScheduledWork?
        /// How long a held queue waits for an answer before it moves on. Far
        /// longer than answering a prompt takes, and far shorter than a session.
        private static let promptFallbackDelay: Double = 60

        var isPaused: Bool { lock.withLock { paused } }

        func setPresenter(_ value: @escaping IamPresentation.Presenter) { lock.withLock { presenter = value } }
        func setDismisser(_ value: @escaping IamPresentation.Dismisser) { lock.withLock { dismisser = value } }
        func setClock(_ value: @escaping @Sendable () -> Double) { lock.withLock { now = value } }
        /// Test-only window onto the persisted state.
        func debugState() -> IamPersistedState { lock.withLock { state } }
        /// Test-only window onto what is waiting to be shown, in order.
        func debugQueuedIds() -> [String] { lock.withLock { queue.map(\.id) } }

        /// Pausing takes the message off the screen without counting it as a
        /// display: it goes back to the front of the queue and is shown again
        /// on unpause. A pause interrupts one presentation rather than ending
        /// it, so the impression latch stays put: a message that had already
        /// rendered is not counted a second time when it comes back. Only
        /// `finish` — a real display — clears the latch.
        func setPaused(_ value: Bool) {
            let (requeued, dismiss): (IamMessage?, IamPresentation.Dismisser) = lock.withLock {
                paused = value
                guard value, let item = current else { return (nil, dismisser) }
                current = nil
                queue.insert(item, at: 0)
                return (item, dismisser)
            }
            if let requeued {
                dismiss()
                OpenPush.onLog(
                    "\u{2022} in-app messages paused — \(requeued.id) returns to the front of the queue")
            }
            if !value { pruneAndPresent() }
        }

        func addTrigger(_ key: String, value: Any) {
            guard !key.isEmpty else { return }
            guard let value = IamTriggerValue(value) else {
                // A value the matcher cannot compare is dropped. Silence here
                // reads as a campaign that never triggers for no visible reason.
                OpenPush.onLog(
                    "\u{2717} trigger '\(key)' ignored — values must be a string, number or boolean")
                return
            }
            lock.withLock { triggers[key] = value; triggerGeneration += 1 }
            pruneAndPresent()
        }
        func removeTriggers(_ keys: [String]) {
            lock.withLock { keys.forEach { triggers[$0] = nil }; triggerGeneration += 1 }
            pruneAndPresent()
        }
        func clearTriggers() {
            lock.withLock { triggers.removeAll(); triggerGeneration += 1 }
            pruneAndPresent()
        }
        func addLifecycle(_ block: @escaping @Sendable (InAppMessageLifecycleEvent) -> Void) -> UUID {
            let id = UUID(); lock.withLock { lifecycle[id] = block }; return id
        }
        func removeLifecycle(_ id: UUID) { lock.withLock { lifecycle[id] = nil } }
        func addClick(_ block: @escaping @Sendable (InAppMessageClickEvent) -> Void) -> UUID {
            let id = UUID(); lock.withLock { clicks[id] = block }; return id
        }
        func removeClick(_ id: UUID) { lock.withLock { clicks[id] = nil } }

        func backgrounded() {
            let now = lock.withLock { self.now }()
            lock.withLock { backgroundAt = now }
        }
        func foregrounded() {
            let now = lock.withLock { self.now }()
            let begins = lock.withLock { () -> Bool in
                guard let backgroundAt, now - backgroundAt >= 30 else { return false }
                self.backgroundAt = nil; sessionStartedAt = now
                // A new session gets a clean slate: a document that failed to
                // load last time is worth one more attempt.
                abandonedThisSession.removeAll()
                return true
            }
            if begins { fetchIfSession(force: false) }
        }

        var fetchesOnSubscriptionReady: Bool { lock.withLock { automaticFetchOnSubscriptionReady } }

        /// Turns the registration-driven fetch off for one test. Production
        /// never calls this, and `resetForTests()` puts it back.
        func setAutomaticFetchForTests(_ enabled: Bool) {
            lock.withLock { automaticFetchOnSubscriptionReady = enabled }
        }

        func fetchIfSession(force: Bool) {
            guard let config = OpenPush.state.config,
                  OpenPush.state.currentSubscriptionID != nil else { return }
            let now = lock.withLock { self.now }()
            let allowed = lock.withLock { () -> Bool in
                guard force || now - lastFetchAt >= 30 else { return false }
                lastFetchAt = now; restore(tokenKey: config.tokenKey); return true
            }
            guard allowed else { return }
            let pending = lock.withLock { () -> OpenPush.ScheduledWork? in
                let handle = fetchRetry; fetchRetry = nil; return handle
            }
            pending?.cancel()
            performFetch(attempt: 1)
        }

        /// The fetch is the whole truth about what may be shown: the definitions
        /// it returns replace the queue, so a campaign the server no longer
        /// returns cannot be shown from a stale copy. A transient failure is
        /// retried on the registration schedule; anything else waits for the
        /// next session.
        private func performFetch(attempt: Int) {
            guard let config = OpenPush.state.config,
                  let sub = OpenPush.state.currentSubscriptionID else { return }
            // Which workspace asked. A switch can land while this is in flight,
            // and everything the completion does — the queue it installs, the
            // purge it runs, the blob it writes — resolves the token key that is
            // current *then*. Without this the leaving workspace's late answer
            // is filed under the incoming workspace's key, overwriting a blob it
            // has no business touching and queueing documents for the wrong
            // audience.
            let tokenKeyAtStart = config.tokenKey
            OpenPush.get("/v1/apps/\(config.appID)/subscriptions/\(sub)/iams") { [weak self] code, body in
                guard let self else { return }
                // Before anything is read from the response, including the retry
                // this failure would otherwise arm: a retry belonging to the
                // workspace the host left has nothing to come back to.
                guard OpenPush.state.config?.tokenKey == tokenKeyAtStart else {
                    OpenPush.onLog("\u{2022} in-app definitions arrived for a workspace the host " +
                                   "has already left — dropped")
                    return
                }
                guard (200...299).contains(code) else {
                    guard OpenPush.isRetryableRegistrationFailure(code),
                          attempt <= OpenPush.registrationRetryDelays.count else {
                        OpenPush.onLog(
                            "\u{2717} in-app definitions could not be fetched (\(code)); " +
                            "the next session tries again")
                        return
                    }
                    let delay = OpenPush.registrationRetryDelays[attempt - 1]
                    let handle = OpenPush.state.schedulerSeam.run(delay) { [weak self] in
                        self?.performFetch(attempt: attempt + 1)
                    }
                    self.lock.withLock { self.fetchRetry = handle }
                    return
                }
                guard let data = body.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rows = root["in_app_messages"] as? [[String: Any]] else { return }
                let messages = rows.compactMap(self.parse)
                // Read before the lock, like every other use of the clock seam.
                let now = self.lock.withLock { self.now }()
                self.lock.withLock {
                    self.fetchRetry = nil
                    self.knownIds = Set(messages.map(\.id))
                    self.latestDefinitions = Dictionary(messages.map { ($0.id, $0) },
                                                        uniquingKeysWith: { _, last in last })
                    let currentId = self.current?.id
                    // The message on screen keeps its slot; it is not in the queue.
                    self.queue = messages.filter { $0.id != currentId }
                    // Only here: this is the first moment the engine can tell a
                    // campaign that is gone from one it simply had not heard
                    // about yet, which is what the purge needs to be safe.
                    self.purgeLocked(now: now)
                    self.persist()
                }
                self.pruneAndPresent()
            }
        }

        private func parse(_ row: [String: Any]) -> IamMessage? {
            guard let id = row["id"] as? String, let html = row["html_path"] as? String else { return nil }
            let groups = (row["triggers"] as? [[[String: Any]]] ?? []).map { group in
                group.compactMap { item -> IamCondition? in
                    guard let kind = item["kind"] as? String,
                          let op = item["operator"] as? String else { return nil }
                    return IamCondition(id: item["id"] as? String ?? UUID().uuidString,
                                        kind: kind, property: item["property"] as? String,
                                        op: op, value: item["value"].flatMap(IamTriggerValue.init))
                }
            }
            let redisplay = row["redisplay"] as? [String: Any]
            return IamMessage(id: id, htmlPath: html, layout: row["layout"] as? String ?? "center",
                              groups: groups,
                              displayDuration: (row["display_duration"] as? NSNumber)?.doubleValue,
                              redisplayLimit: (redisplay?["limit"] as? NSNumber)?.intValue ?? 1,
                              redisplayDelay: (redisplay?["delay"] as? NSNumber)?.doubleValue ?? 0,
                              endTime: IamEngine.epochSeconds(row["end_time"]))
        }

        /// The server sends `end_time` as epoch seconds; an ISO-8601 string is
        /// accepted too, with or without fractional seconds.
        private static func epochSeconds(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            guard let text = value as? String, !text.isEmpty else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date.timeIntervalSince1970 }
            return ISO8601DateFormatter().date(from: text)?.timeIntervalSince1970
        }

        /// Called only while `lock` is held. Keeping this lock-free avoids the
        /// recursive NSLock acquisition that previously froze the engine after
        /// a successful eligibility fetch, before a WebView could be created.
        private func eligibleLocked(_ message: IamMessage, now: Double) -> Bool {
            if let end = message.endTime, now >= end { return false }
            guard OpenPush.iamConditionsMatch(message.groups, triggers: triggers,
                                              sessionAge: max(0, now - sessionStartedAt),
                                              timeSinceLast: state.lastTimeInAppDismissed.map { now - $0 }
                                                ?? Double.greatestFiniteMagnitude) else { return false }
            guard let redisplay = state.redisplay[message.id] else {
                return !state.dismissed.contains(message.id)
            }
            return triggerGeneration != displayedGeneration[message.id]
                && now - redisplay.lastDisplayTime >= message.redisplayDelay
                && redisplay.displayQuantity < message.redisplayLimit
        }

        /// Called only while `lock` is held. A message leaves the queue only
        /// when it can never be shown again; one that is merely waiting for its
        /// conditions keeps its place in line.
        private func retiredLocked(_ message: IamMessage) -> Bool {
            if abandonedThisSession.contains(message.id) { return true }
            guard let redisplay = state.redisplay[message.id] else {
                return state.dismissed.contains(message.id)
            }
            return redisplay.displayQuantity >= message.redisplayLimit
        }

        private func pruneAndPresent() {
            let now = lock.withLock { self.now }()
            let (next, token, present): (IamMessage?, Int, IamPresentation.Presenter) = lock.withLock {
                guard !paused, !awaitingPrompt, current == nil else { return (nil, 0, presenter) }
                queue.removeAll { retiredLocked($0) }
                guard let index = queue.firstIndex(where: { eligibleLocked($0, now: now) })
                else { return (nil, 0, presenter) }
                let item = queue.remove(at: index); current = item
                presentationToken += 1; currentToken = presentationToken
                return (item, currentToken, presenter)
            }
            scheduleDynamicReevaluation(now: now)
            guard let next else { return }
            emit(next, .willDisplay)
            present(next) { [weak self] event in self?.handle(next, event: event, token: token) }
        }

        /// A `session_time` or `min_time_since` condition becomes true with
        /// nothing to announce it: no trigger is set, no fetch lands, and the
        /// message would sit in the queue until something unrelated re-evaluated
        /// it. Wake the engine once, just past the earliest such deadline in the
        /// queue, so the message that is only waiting on the clock is shown.
        private func scheduleDynamicReevaluation(now: Double) {
            let scheduler = OpenPush.state.schedulerSeam
            let (previous, deadline): (OpenPush.ScheduledWork?, Double?) = lock.withLock {
                let previous = dynamicTimer
                dynamicTimer = nil
                let sessionAge = max(0, now - sessionStartedAt)
                let since = state.lastTimeInAppDismissed.map { now - $0 } ?? Double.greatestFiniteMagnitude
                // A message that can never be shown again has no deadline worth
                // waking for; only what is still in the running counts.
                let next = queue.filter { !retiredLocked($0) }.compactMap {
                    OpenPush.iamNextDynamicDeadline($0.groups, triggers: triggers,
                                                    sessionAge: sessionAge, timeSinceLast: since)
                }.min()
                return (previous, next)
            }
            previous?.cancel()
            guard let deadline else { return }
            // A hair past the deadline: at the deadline itself the condition is
            // only just equal, and `greater` would still be false.
            let handle = scheduler.run(deadline + 0.05) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.dynamicTimer = nil; self.triggerGeneration += 1 }
                self.pruneAndPresent()
            }
            lock.withLock { dynamicTimer = handle }
        }

        /// Nothing is counted until the presenter says the document is on
        /// screen: `willDisplay` is a request to show, `didDisplay` is a fact.
        private func handle(_ message: IamMessage, event: IamPresentation.Event, token: Int) {
            // A presentation that is over keeps its emit closure alive. Anything
            // it sends afterwards is about a message nobody is looking at — and
            // the token says so even when the same message is on screen again.
            guard lock.withLock({ current?.id == message.id && currentToken == token })
            else { return }
            switch event {
            case .rendered:
                let first = lock.withLock { state.impressioned.insert(message.id).inserted }
                guard first else { return }
                lock.withLock { persist() }
                emit(message, .didDisplay)
                impression(message)
            case .pageChanged(let pageId, _):
                pageImpression(message, pageId: pageId)
            case .action(let action):
                handle(message, action: action)
            case .failed(let reason):
                OpenPush.onLog("\u{2717} in-app message \(message.id) could not be shown: \(reason)")
                abandon(message)
            }
        }

        /// The message was never on screen: nothing is counted, and it is skipped
        /// for the rest of this session so a broken document cannot loop.
        private func abandon(_ message: IamMessage) {
            lock.withLock {
                if current?.id == message.id { current = nil }
                abandonedThisSession.insert(message.id)
                state.impressioned.remove(message.id)
                persist()
            }
            pruneAndPresent()
        }

        private func impression(_ message: IamMessage) {
            guard let config = OpenPush.state.config,
                  let token = OpenPush.currentToken else { return }
            let messageID = message.id
            OpenPush.post("/v1/ingest", ["events": [[
                "app": config.appID, "token": token,
                "type": "iam_impression", "message_id": messageID,
            ]]]) { code, body in
                OpenPush.IamEngine.logReceiptOutcome("impression", messageID, code: code, body: body)
            }
        }

        /// A carousel page is counted the first time a reader reaches it, and only
        /// then: swiping back to a card already seen is not a new impression.
        /// Nothing counts before the document itself has rendered — the
        /// impression latch is what says a human can see this message at all.
        private func pageImpression(_ message: IamMessage, pageId: String) {
            guard !pageId.isEmpty, let config = OpenPush.state.config,
                  let token = OpenPush.currentToken else { return }
            let first = lock.withLock { () -> Bool in
                guard state.impressioned.contains(message.id),
                      state.pageImpressions.insert("\(message.id)|\(pageId)").inserted
                else { return false }
                persist()
                return true
            }
            guard first else { return }
            let messageID = message.id
            OpenPush.post("/v1/ingest", ["events": [[
                "app": config.appID, "token": token,
                "type": "iam_page_impression", "message_id": messageID,
                // Both keys carry the same value: the server reads either.
                "page_id": pageId, "card_id": pageId,
            ]]]) { code, body in
                OpenPush.IamEngine.logReceiptOutcome("page impression", messageID,
                                                     code: code, body: body)
            }
        }

        /// A receipt the server never accepted is a silently miscounted campaign.
        /// Say so once, at the point of failure, instead of discarding the result.
        static func logReceiptOutcome(_ kind: String, _ messageId: String, code: Int, body: String) {
            if !(200...299).contains(code) {
                OpenPush.onLog("\u{2717} in-app \(kind) receipt for \(messageId) failed (\(code))")
                return
            }
            if let data = body.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dropped = (root["dropped"] as? NSNumber)?.intValue, dropped > 0 {
                OpenPush.onLog("\u{2717} in-app \(kind) receipt for \(messageId) was dropped by the server")
            }
        }

        private func handle(_ message: IamMessage, action: IamPresentation.Action) {
            if let clickID = action.clickID, let config = OpenPush.state.config,
               let token = OpenPush.currentToken {
                // Both answers come out of one turn under the lock: a click id
                // already reported is not reported again, and the first click
                // on a message is the first only once, however many times the
                // message is shown.
                let (shouldSend, first): (Bool, Bool) = lock.withLock {
                    var ids = state.clickedByMessage[message.id] ?? []
                    let inserted = ids.insert(clickID).inserted
                    state.clickedByMessage[message.id] = ids
                    let first = inserted && state.firstClicked.insert(message.id).inserted
                    if inserted { persist() }
                    return (inserted, first)
                }
                if shouldSend {
                    let messageID = message.id
                    OpenPush.post("/v1/ingest", ["events": [[
                        "app": config.appID, "token": token,
                        "type": "iam_click", "message_id": messageID,
                        "click_id": clickID, "block_key": action.blockKey ?? "",
                        "action_id": action.actionID ?? "", "first_click": first,
                    ]]]) { code, body in
                        OpenPush.IamEngine.logReceiptOutcome("click", messageID, code: code, body: body)
                    }
                }
                let event = InAppMessageClickEvent(messageId: message.id, actionId: action.actionID,
                                                   url: action.url, urlTarget: action.urlTarget,
                                                   closingMessage: action.closes,
                                                   firstClick: first)
                let listeners = lock.withLock { Array(clicks.values) }
                OpenPush.deliverOnMain { listeners.forEach { $0(event) } }
            }
            // A system prompt is the person's next decision, and it belongs to
            // the message that asked for it. The slot is held — closed message
            // or not — until the answer comes back through `promptFinished`.
            // The next message would otherwise arrive under an alert nobody
            // has answered yet: unreadable, and dismissed blind.
            if action.holdsQueue { holdForPrompt() }
            if action.closes { finish(message, dismissed: true) }
        }

        /// Holds the slot, and arms the one wake-up that gives it back. A
        /// prompt whose answer never arrives — the person was sent to Settings
        /// and never came back, or the system raised nothing at all — would
        /// otherwise hold every remaining message for the rest of the session.
        private func holdForPrompt() {
            // Armed before the lock is taken and stored inside the same turn
            // that sets the hold, so the state never says "held" while the
            // wake-up that ends the hold is not yet recorded anywhere.
            let handle = OpenPush.state.schedulerSeam.run(Self.promptFallbackDelay) { [weak self] in
                guard let self else { return }
                let stuck = self.lock.withLock { () -> Bool in
                    self.promptFallback = nil
                    guard self.awaitingPrompt else { return false }
                    self.awaitingPrompt = false
                    return true
                }
                guard stuck else { return }
                OpenPush.onLog(
                    "\u{2022} in-app permission prompt never reported an answer — the queue moves on")
                self.pruneAndPresent()
            }
            let previous: OpenPush.ScheduledWork? = lock.withLock {
                awaitingPrompt = true
                let stale = promptFallback; promptFallback = handle; return stale
            }
            previous?.cancel()
        }

        /// The prompt is off the screen — granted, denied, or never shown at
        /// all. Whatever the answer was, the queue moves again.
        func promptFinished() {
            let pending: OpenPush.ScheduledWork? = lock.withLock {
                awaitingPrompt = false
                let handle = promptFallback; promptFallback = nil; return handle
            }
            pending?.cancel()
            pruneAndPresent()
        }

        private func finish(_ message: IamMessage, dismissed: Bool) {
            emit(message, .willDismiss)
            let now = lock.withLock { self.now }()
            lock.withLock {
                if current?.id == message.id { current = nil }
                // The next display cycle posts its own impression.
                state.impressioned.remove(message.id)
                if dismissed { state.dismissed.insert(message.id) }
                var record = state.redisplay[message.id] ?? .init(lastDisplayTime: now, displayQuantity: 0)
                record.lastDisplayTime = now; record.displayQuantity += 1
                state.redisplay[message.id] = record; state.lastTimeInAppDismissed = now
                displayedGeneration[message.id] = triggerGeneration
                // Budget left means this message can come back: it rejoins the
                // queue and waits for the trigger change that shows it again —
                // but only while the server still returns it, and always as the
                // definition the server returned last. Before the first fetch
                // lands nothing is known to be gone, so nothing is held back.
                let definition = latestDefinitions[message.id] ?? message
                // A display that can be repeated re-arms its clicks and its
                // carousel pages: what was reported during this display must
                // not silence the next one, where the same block is a click
                // nobody has made yet and the same card is a page nobody has
                // reached yet.
                if definition.redisplayLimit > 1 {
                    state.clickedByMessage[message.id] = []
                    let prefix = message.id + "|"
                    state.pageImpressions = state.pageImpressions.filter { !$0.hasPrefix(prefix) }
                }
                persist()
                if knownIds?.contains(message.id) ?? true,
                   record.displayQuantity < definition.redisplayLimit,
                   !queue.contains(where: { $0.id == message.id }) {
                    queue.append(definition)
                }
            }
            emit(message, .didDismiss); pruneAndPresent()
        }

        private func emit(_ message: IamMessage, _ stage: InAppMessageLifecycleEvent.Stage) {
            let event = InAppMessageLifecycleEvent(messageId: message.id, stage: stage,
                                                   layout: message.layout)
            // Every stage, from every path — the fetch response, a trigger call,
            // the scheduler, WebKit — reaches the host on the main thread, in the
            // order the engine raised it.
            let listeners = lock.withLock { Array(lifecycle.values) }
            OpenPush.deliverOnMain { listeners.forEach { $0(event) } }
        }
        private func key(_ tokenKey: String) -> String { tokenKey + ".iamState" }
        /// Reads the blob back and nothing more. The purge deliberately does not
        /// run here: on a cold start the queue is empty and no fetch has said
        /// which messages still exist, so everything would look like history —
        /// including the click state of a message that was on screen when the
        /// process was killed. It runs once the fetch has answered instead.
        private func restore(tokenKey: String) {
            // The caller read this out of `State` before taking this lock, which
            // is the only way the engine is allowed to learn it.
            cachedTokenKey = tokenKey
            guard let data = UserDefaults.standard.data(forKey: key(tokenKey)),
                  let decoded = try? JSONDecoder().decode(IamPersistedState.self, from: data) else { return }
            // The latch only ever means "this presentation is already counted",
            // so only the message actually on screen may keep it. Anything else
            // — a latch left by a process killed between the render and the
            // dismiss — would silently suppress the next impression.
            let stillOnScreen = current.map { state.impressioned.contains($0.id) ? [$0.id] : [] } ?? []
            state = decoded
            state.impressioned = Set(stillOnScreen)
        }

        /// Called only while `lock` is held, and only once a fetch has said
        /// which messages are live. The blob is carried for the life of the
        /// install, so it only ever grows unless something lets go: a campaign
        /// last seen half a year ago is history, and the click state of a
        /// message the engine no longer remembers at all is bookkeeping about
        /// nothing.
        ///
        /// "No longer remembers" is the whole difficulty. Run before the fetch
        /// answers, the engine remembers nothing at all, and a message that was
        /// on screen when the process died — clicked, never dismissed, with no
        /// `redisplay` record to its name — reads as a campaign from last year.
        /// Dropping its clicks makes the fetch that brings it back report the
        /// same click as a first click a second time.
        private func purgeLocked(now: Double) {
            let cutoff = now - 180 * 86_400
            state.redisplay = state.redisplay.filter { $0.value.lastDisplayTime >= cutoff }
            // A message that has never finished a display has no record in
            // `redisplay` or `dismissed` and is still the one being clicked:
            // what is on screen or waiting in line keeps its click state.
            // `knownIds` is the fetch's own answer about what exists, and it is
            // wider than the queue: a message the server still returns but that
            // is not eligible right now is live all the same.
            let live = Set(queue.map(\.id))
                .union(current.map { [$0.id] } ?? [])
                .union(knownIds ?? [])
            let known = Set(state.redisplay.keys).union(state.dismissed).union(live)
            state.clickedByMessage = state.clickedByMessage.filter { known.contains($0.key) }
            state.firstClicked = state.firstClicked.intersection(known)
            // The key is "<message id>|<page id>": everything up to the first
            // separator is the message the page belongs to.
            state.pageImpressions = state.pageImpressions.filter { key in
                guard let id = key.split(separator: "|", maxSplits: 1).first else { return false }
                return known.contains(String(id))
            }
        }
        /// Called only while `lock` is held, like every other writer of `state`.
        private func persist() {
            guard let tokenKey = cachedTokenKey,
                  let data = try? JSONEncoder().encode(state) else { return }
            UserDefaults.standard.set(data, forKey: key(tokenKey))
        }

        /// A different workspace is a different audience: nothing the previous
        /// one queued, triggered or counted may follow the host into it, and the
        /// document on screen belongs to the workspace that queued it. Clearing
        /// memory is not enough — hosts that keep the default token key share one
        /// persisted blob between workspaces, so the next fetch's restore would
        /// read the previous workspace's display and click history straight back
        /// in. The blob of the workspace being left goes, exactly as the session
        /// and Custom Event stores do; where the host gave each workspace a key
        /// of its own, that is a different blob from the one the workspace being
        /// entered will restore on its next fetch, and its display and click
        /// history is its own.
        ///
        /// Called from `attach` after `State.setup` returns, never from inside
        /// it: `State`'s lock and this one must never nest.
        /// Told to the engine by `attach`, after `State.setup` has returned and
        /// outside `State`'s lock. Every attach calls it, so the engine always
        /// knows which workspace's blob is its own — including the switch, where
        /// `workspaceSwitched` has just forgotten the previous one.
        func adoptTokenKey(_ tokenKey: String) {
            lock.withLock { cachedTokenKey = tokenKey }
        }

        func workspaceSwitched(previousTokenKey: String?) {
            let (pending, dismiss): ([OpenPush.ScheduledWork], IamPresentation.Dismisser) =
                lock.withLock {
                    triggers.removeAll()
                    queue.removeAll()
                    current = nil
                    abandonedThisSession.removeAll()
                    displayedGeneration.removeAll()
                    knownIds = nil
                    latestDefinitions.removeAll()
                    // Nothing may be written under the workspace being left, and
                    // the one being entered is `attach`'s to name: it calls
                    // `adoptTokenKey` the moment this returns.
                    cachedTokenKey = nil
                    state = IamPersistedState()
                    paused = false
                    awaitingPrompt = false
                    backgroundAt = nil
                    lastFetchAt = 0
                    let handles = [fetchRetry, dynamicTimer, promptFallback].compactMap { $0 }
                    fetchRetry = nil; dynamicTimer = nil; promptFallback = nil
                    return (handles, dismisser)
                }
            pending.forEach { $0.cancel() }
            if let previousTokenKey {
                UserDefaults.standard.removeObject(forKey: key(previousTokenKey))
            }
            dismiss()
        }

        func resetForTests() {
            var tokenKey: String?
            let pending = lock.withLock { () -> [OpenPush.ScheduledWork] in
                tokenKey = cachedTokenKey
                cachedTokenKey = nil
                triggers.removeAll()
                queue.removeAll()
                current = nil
                state = IamPersistedState()
                paused = false
                automaticFetchOnSubscriptionReady = true
                awaitingPrompt = false
                backgroundAt = nil
                sessionStartedAt = Date().timeIntervalSince1970
                lastFetchAt = 0
                triggerGeneration = 0
                displayedGeneration.removeAll()
                lifecycle.removeAll()
                clicks.removeAll()
                presenter = IamPresentation.system
                dismisser = IamPresentation.systemDismiss
                now = { Date().timeIntervalSince1970 }
                abandonedThisSession.removeAll()
                presentationToken = 0
                currentToken = 0
                knownIds = nil
                latestDefinitions.removeAll()
                let handles = [fetchRetry, dynamicTimer, promptFallback].compactMap { $0 }
                fetchRetry = nil; dynamicTimer = nil; promptFallback = nil
                return handles
            }
            pending.forEach { $0.cancel() }
            if let tokenKey {
                UserDefaults.standard.removeObject(forKey: key(tokenKey))
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
