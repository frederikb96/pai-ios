#if DEBUG

    import Foundation

    /// Puts the fixture notes on disk as if they had been opened before, for the offline
    /// screenshots: the index, the fixture note, its attachment inventory and both attachments
    /// (the image and the PDF the app renders), and, under `-PaiFixtureNotePendingEdit`, an edit
    /// to that note made offline and not yet synced.
    ///
    /// Each piece is written only when it is missing. The screenshot run relaunches the app once
    /// per screen against the same simulator, and an earlier screen may already have cached some
    /// of it the ordinary way; a pending edit synced by one screen is seeded again for the next.
    public enum PaiFixtureNotesSeed {
        public static func seed(
            cache: NotesCacheStorage, outbox: NoteOutboxStorage, pdf: Data,
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) {
            let decoder = JSONDecoder()
            guard let detail = try? decoder.decode(NoteDetail.self, from: PaiFixtures.data(PaiFixtures.noteDetail))
            else { return }

            if PaiFixtureLaunch.seedsNotesCache(arguments: arguments) {
                if cache.loadIndex() == nil,
                    let page = try? decoder.decode(IndexPage.self, from: PaiFixtures.data(PaiFixtures.notesIndex))
                {
                    cache.saveIndex(CachedNoteIndex(notes: page.notes))
                }
                if cache.loadBody(noteId: detail.id) == nil { cache.saveBody(detail) }
                if let containerId = detail.containerId,
                    let page = try? decoder.decode(
                        InventoryPage.self, from: PaiFixtures.data(PaiFixtures.noteAttachments))
                {
                    if cache.loadInventory(containerId: containerId) == nil {
                        cache.saveInventory(page.attachments, containerId: containerId)
                    }
                    seedAttachments(page.attachments, containerId: containerId, cache: cache, pdf: pdf)
                }
            }

            if PaiFixtureLaunch.seedsNotePendingEdit(arguments: arguments),
                !outbox.loadEdits().contains(where: { $0.noteId == detail.id })
            {
                outbox.saveEdit(
                    NotePendingEdit(
                        noteId: detail.id, body: detail.body + PaiFixtures.notePendingEditSuffix, base: detail,
                        editedAtMs: detail.updatedAtMs + 60_000, awaitingSync: true))
            }
        }

        private static func seedAttachments(
            _ records: [NoteAttachmentRecord], containerId: String, cache: NotesCacheStorage, pdf: Data
        ) {
            var manifest = cache.loadAttachmentManifest()
            for record in records where !manifest.contains(where: { $0.path == record.relPath }) {
                let bytes = record.ext == "pdf" ? pdf : PaiFixtures.attachmentImage
                let fileId = "fixture-\(record.basename)"
                guard cache.writeAttachment(bytes, fileId: fileId) else { continue }
                manifest.append(
                    CachedAttachment(
                        fileId: fileId, containerId: containerId, path: record.relPath, byteCount: bytes.count,
                        sizeBytes: record.sizeBytes, mtimeMs: record.mtimeMs, lastUsedMs: record.mtimeMs))
            }
            cache.saveAttachmentManifest(manifest)
        }

        private struct IndexPage: Decodable {
            let notes: [NoteSummary]
        }

        private struct InventoryPage: Decodable {
            let attachments: [NoteAttachmentRecord]
        }
    }

#endif
