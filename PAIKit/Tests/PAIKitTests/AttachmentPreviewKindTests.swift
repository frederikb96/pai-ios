import Testing

@testable import PAIKit

@Suite("Attachment preview kind")
struct AttachmentPreviewKindTests {

    @Test("Images and PDFs preview in place; everything else does not")
    func kindsByExtension() {
        #expect(AttachmentPreviewKind(path: "shot.png") == .image)
        #expect(AttachmentPreviewKind(path: "menu.pdf") == .pdf)
        #expect(AttachmentPreviewKind(path: "notes.docx") == .other)
        #expect(AttachmentPreviewKind(path: "archive") == .other)
        #expect(AttachmentPreviewKind(path: "menu.pdf").isPreviewable)
        #expect(!AttachmentPreviewKind(path: "notes.docx").isPreviewable)
    }

    /// A phone names its photos in capitals, and a mail attachment may be `MENU.PDF`.
    @Test("The extension matches whatever its case")
    func caseInsensitive() {
        #expect(AttachmentPreviewKind(path: "IMG_0001.HEIC") == .image)
        #expect(AttachmentPreviewKind(path: "MENU.PDF") == .pdf)
    }

    /// The failure this guards: matching ".pdf" anywhere in the path, so a directory named like a
    /// PDF makes every file inside it open in the PDF viewer.
    @Test("Only the last path component decides")
    func lastComponentOnly() {
        #expect(AttachmentPreviewKind(path: "/home/user/reports.pdf/readme.txt") == .other)
        #expect(AttachmentPreviewKind(path: "/home/user/pictures.png/menu.pdf") == .pdf)
        #expect(AttachmentPreviewKind(path: "attachments/2026/photo.jpeg") == .image)
    }

    @Test("A bare extension in the name is not a file type")
    func extensionNeedsAStem() {
        #expect(AttachmentPreviewKind(path: "pdf") == .other)
        #expect(AttachmentPreviewKind(path: "/tmp/notapdf") == .other)
    }

    @Test("The image predicate follows the kind")
    func imagePredicate() {
        #expect(isImageAttachmentPath("a/b/c.webp"))
        #expect(!isImageAttachmentPath("a/b/c.pdf"))
    }

    @Test("The filename is the last component")
    func filename() {
        #expect(attachmentFilename("/a/b/c.pdf") == "c.pdf")
        #expect(attachmentFilename("c.pdf") == "c.pdf")
    }
}
