#if DEBUG

    import Foundation

    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// Query-driven answers for `GET /api/session/{id}/messages` and its `/find` sibling — the
    /// only two fixture routes whose body genuinely depends on the query string, because a
    /// `locate` landing genuinely depends on WHICH page of the corpus was asked for. Every other
    /// route in `PaiFixtureURLProtocol`'s table answers one fixed body regardless of the request.
    extension PaiFixtureURLProtocol {

        /// Slices `PaiFixtures.transcript` the same way the real endpoint pages it —
        /// `tail`/`before_id`/`after_id`/`around_id` — so a jump into unloaded history actually
        /// gets a page that does or does not overlap the currently loaded window, rather than the
        /// same fixed transcript regardless of what was asked for. No recognised paging parameter
        /// (or no query at all) answers the whole corpus, matching this route's behaviour before
        /// any of this existed.
        static func messagesResponse(query: [URLQueryItem]) -> Data {
            let entries = parsedTranscript
            if let aroundId = intValue("around_id", in: query) {
                return encode(sliceAround(aroundId, limit: intValue("limit", in: query) ?? 150, in: entries))
            }
            if let beforeId = intValue("before_id", in: query) {
                return encode(sliceBefore(beforeId, limit: intValue("limit", in: query) ?? 150, in: entries))
            }
            if let afterId = intValue("after_id", in: query) {
                return encode(sliceAfter(afterId, limit: intValue("limit", in: query) ?? 150, in: entries))
            }
            if query.contains(where: { $0.name == "tail" }) {
                return encode(sliceTail(limit: intValue("limit", in: query) ?? 300, in: entries))
            }
            return PaiFixtures.data(PaiFixtures.transcript)
        }

        /// `q`/`kind` for `GET /api/session/{id}/messages/find` — ids only, an exact total, and a
        /// snapshot marker (`MessageFindResult`'s own doc comment), never the messages themselves.
        ///
        /// `kind: boundary` is the one predicate this needs to be genuinely right: `min(id)` of
        /// the session plus every `system`/`compact` row is exactly what reproduces "Session
        /// start"/"Compaction" landing on the wrong place, the bug this whole fixture corpus
        /// exists to prove fixed. A text query is a plain case-insensitive substring match over
        /// `content`/`thinking` — nothing served here needs `pg_trgm`'s own recall behaviour, and
        /// the fixture's own job (search-virtualization design, "matching: server recall, client
        /// precision") is only ever to hand back a superset the client can narrow, not to match
        /// exactly.
        static func findResponse(query: [URLQueryItem]) -> Data {
            let entries = parsedTranscript
            var ids: [Int]
            if let kind = stringValue("kind", in: query) {
                ids = matchedIds(forKind: kind, in: entries)
            } else if let q = stringValue("q", in: query), !q.isEmpty {
                ids = matchedIds(forQuery: q, in: entries)
            } else {
                ids = []
            }
            ids.sort()
            let asOfId = entries.compactMap { $0["id"] as? Int }.max().map(String.init) ?? "null"
            let body = """
                {"message_ids": [\(ids.map(String.init).joined(separator: ","))], "total": \(ids.count), \
                "as_of_id": \(asOfId), "capped": false}
                """
            return PaiFixtures.data(body)
        }

        // MARK: - Query helpers

        private static func stringValue(_ name: String, in query: [URLQueryItem]) -> String? {
            query.first { $0.name == name }?.value
        }

        private static func intValue(_ name: String, in query: [URLQueryItem]) -> Int? {
            stringValue(name, in: query).flatMap(Int.init)
        }

        // MARK: - Matching

        private static func matchedIds(forKind kind: String, in entries: [[String: Any]]) -> [Int] {
            guard kind == "boundary" else { return [] }
            guard let minId = entries.compactMap({ $0["id"] as? Int }).min() else { return [] }
            var ids = [minId]
            for entry in entries {
                guard let id = entry["id"] as? Int, entry["type"] as? String == "system",
                    entry["subtype"] as? String == "compact"
                else { continue }
                ids.append(id)
            }
            return ids
        }

        private static func matchedIds(forQuery query: String, in entries: [[String: Any]]) -> [Int] {
            let needle = query.lowercased()
            return entries.compactMap { entry -> Int? in
                guard let id = entry["id"] as? Int else { return nil }
                let haystacks = [entry["content"] as? String, entry["thinking"] as? String].compactMap { $0 }
                return haystacks.contains { $0.lowercased().contains(needle) } ? id : nil
            }
        }

        // MARK: - Paging

        private static func sliceTail(limit: Int, in entries: [[String: Any]]) -> [[String: Any]] {
            Array(entries.suffix(max(0, limit)))
        }

        private static func sliceBefore(_ id: Int, limit: Int, in entries: [[String: Any]]) -> [[String: Any]] {
            let older = entries.filter { ($0["id"] as? Int ?? Int.max) < id }
            return Array(older.suffix(max(0, limit)))
        }

        private static func sliceAfter(_ id: Int, limit: Int, in entries: [[String: Any]]) -> [[String: Any]] {
            let newer = entries.filter { ($0["id"] as? Int ?? Int.min) > id }
            return Array(newer.prefix(max(0, limit)))
        }

        /// `ceil(limit/2)` at-or-before `id`, `floor(limit/2)` after — the same split
        /// `PaiApiClient.messages(around:limit:sessionId:)`'s own doc comment describes for the
        /// real endpoint.
        private static func sliceAround(_ id: Int, limit: Int, in entries: [[String: Any]]) -> [[String: Any]] {
            let before = entries.filter { ($0["id"] as? Int ?? Int.max) <= id }
            let after = entries.filter { ($0["id"] as? Int ?? Int.min) > id }
            let beforeCount = Int((Double(limit) / 2).rounded(.up))
            let afterCount = limit - beforeCount
            return Array(before.suffix(max(0, beforeCount))) + Array(after.prefix(max(0, afterCount)))
        }

        // MARK: - Parsing

        /// Parsed once and cached — every route above reads the same corpus, and re-parsing a
        /// multi-hundred-row JSON string on every request this session's own screenshot workflow
        /// makes would be wasted work for a value that never changes. `nonisolated(unsafe)`: `Any`
        /// cannot be proven `Sendable`, but this is written exactly once, by `static let`'s own
        /// one-time initialization, and never mutated after — the same reasoning
        /// `PAIApp.swift`'s `routeNames` already relies on for the same shape of value.
        private static nonisolated(unsafe) let parsedTranscript: [[String: Any]] = {
            guard let data = PaiFixtures.transcript.data(using: .utf8),
                let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return [] }
            return array.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        }()

        private static func encode(_ entries: [[String: Any]]) -> Data {
            (try? JSONSerialization.data(withJSONObject: entries, options: [])) ?? Data("[]".utf8)
        }
    }

#endif
