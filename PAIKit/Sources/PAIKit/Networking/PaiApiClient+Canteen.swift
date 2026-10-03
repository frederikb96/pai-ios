import Foundation

extension PaiApiClient {

    // MARK: Canteen

    /// The canteen mails, newest first.
    public func listCanteenEntries() async throws -> [CanteenEntry] {
        let response: CanteenEntriesResponse = try await send(path: "/api/canteen/entries")
        return response.entries
    }

    /// One stored PDF's bytes. The route needs the bearer header, which is why a PDF is fetched
    /// here and handed to the system viewer as a file rather than opened by URL.
    public func getCanteenAttachment(entryId: String, attachmentId: String) async throws -> Data {
        try await sendPassingThrough(
            path: "/api/canteen/entries/\(entryId)/attachments/\(attachmentId)",
            method: "GET",
            contentType: nil,
            passthrough: []
        ).body
    }
}
