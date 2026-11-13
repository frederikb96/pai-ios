import Foundation

extension PaiApiClient {

    // MARK: Browser

    /// A session name is limited to `[A-Za-z0-9._-]` by the backend, so nothing here needs
    /// escaping; the encode is for a name that was never validated (a hand-typed link).
    static func browserSessionPath(_ name: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return "/api/browser/sessions/\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)"
    }

    /// Every live agent browser session. Owner only: the route answers a guest 403, so callers
    /// ask `Capabilities.canOpenBrowser` first.
    public func listBrowserSessions() async throws -> [BrowserSession] {
        let response: BrowserSessionsResponse = try await send(path: "/api/browser/sessions")
        return response.sessions
    }

    /// One input event into a session being watched; a 409 means nobody is watching it.
    public func sendBrowserInput(name: String, input: BrowserInput) async throws {
        try await sendDiscardingResponse(
            path: Self.browserSessionPath(name) + "/input", method: "POST", body: try Self.jsonBody(input))
    }

    /// Ends a handover; the backend messages the owning conversation.
    public func handBackBrowserSession(
        name: String, result: BrowserHandbackResult, note: String? = nil
    ) async throws -> BrowserHandbackAnswer {
        struct Body: Encodable {
            let result: String
            let note: String?
        }
        return try await send(
            path: Self.browserSessionPath(name) + "/handback", method: "POST",
            body: try Self.jsonBody(Body(result: result.rawValue, note: note)))
    }
}
