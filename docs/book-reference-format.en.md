# StackNest Reference File (.stacknestbook)

[日本語](book-reference-format.md) | **English**

The documentation for authors of external viewers **has moved to the StackNestViewerKit repository**. Declaring support, the type, the contents of the reference file, the book API, the identification header, checking that the book was loaded, what we ask of viewers, security notes and versions are all described there.

- Format document: [Documentation/BookReferenceFormat.en.md](https://github.com/shelfsmith/StackNestViewerKit/blob/main/Documentation/BookReferenceFormat.en.md) ([日本語](https://github.com/shelfsmith/StackNestViewerKit/blob/main/Documentation/BookReferenceFormat.md))
- Sample reference files: [Documentation/Samples](https://github.com/shelfsmith/StackNestViewerKit/tree/main/Documentation/Samples)

A viewer written in Swift can add the [StackNestViewerKit](https://github.com/shelfsmith/StackNestViewerKit) package (MIT, no dependencies) with SwiftPM to read reference files, fetch pages and write back the reading position exactly as the document describes. StackNest itself writes reference files with this package's type.

The StackNest setting ("Sync Reading Position with StackNest (Supported Apps Only)") is described in the in-app help (⌘?) under "External Viewer". The full text of this document before it was replaced by this pointer is in this repository's history.
