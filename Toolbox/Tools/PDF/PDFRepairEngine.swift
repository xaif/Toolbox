import AppKit
import Compression
import ImageIO
import PDFKit

/// A PDF read byte by byte without trusting its cross-reference table: every "N G obj … endobj" in file
/// order, with the objects packed in object streams unpacked. Repair rebuilds damaged files from it, and
/// the privacy cleaner patches rewritten files in place with it.
struct PDFRawFile {
    struct Object {
        let number: Int
        let generation: Int
        /// The object's value, usually a dictionary, as written.
        let value: Data
        /// Absolute byte range of `value`. Nil for objects unpacked from an object stream.
        let valueRange: Range<Int>?
        /// The stream's encoded bytes, for stream objects.
        let stream: Data?
        /// Absolute byte range of `stream`.
        let streamRange: Range<Int>?

        var text: String { String(data: value, encoding: .isoLatin1) ?? "" }
    }

    /// A trailer dictionary (classic, or a cross-reference stream's) and where it is.
    struct Trailer {
        let text: String
        let range: Range<Int>
    }

    let bytes: [UInt8]
    /// Complete objects in file order. Where a number repeats (incremental updates), the last one wins.
    private(set) var objects: [Object] = []
    private(set) var trailers: [Trailer] = []
    /// Numbers of objects cut off before their end, with what was there.
    private(set) var incomplete: [(number: Int, text: String)] = []
    private(set) var unreadableObjectStreams = 0

    init(data: Data) {
        bytes = [UInt8](data)
        scan()
    }

    /// The last complete copy of each object.
    var latest: [Int: Object] {
        var result: [Int: Object] = [:]
        for object in objects { result[object.number] = object }
        return result
    }

    // MARK: Scanning

    private mutating func scan() {
        var index = 0
        let objPattern = Array("obj".utf8), trailerPattern = Array("trailer".utf8)
        var nextTrailer = find(trailerPattern, from: 0)
        while index < bytes.count {
            if let trailer = nextTrailer, trailer < index { nextTrailer = find(trailerPattern, from: index) }
            let nextObj = find(objPattern, from: index)
            guard nextObj != nil || nextTrailer != nil else { break }
            if let trailer = nextTrailer, trailer < (nextObj ?? .max) {
                index = trailer + trailerPattern.count
                let start = skipSpace(index)
                if start + 1 < bytes.count, bytes[start] == 0x3C, bytes[start + 1] == 0x3C, let end = valueEnd(from: start) {
                    trailers.append(Trailer(text: latin1(start..<end), range: start..<end))
                    index = end
                }
                continue
            }
            let position = nextObj!
            index = position + objPattern.count
            guard let (number, generation, _) = header(endingAt: position),
                  index >= bytes.count || isDelimiterOrSpace(bytes[index]) else { continue }
            index = parseObject(number: number, generation: generation, bodyStart: index)
        }
        unpackObjectStreams()
    }

    /// Parses the object whose "obj" keyword ends at `bodyStart`. Returns where scanning continues.
    private mutating func parseObject(number: Int, generation: Int, bodyStart: Int) -> Int {
        let body = scanBody(from: bodyStart)
        let valueStart = skipSpace(bodyStart)
        let valueRange = valueStart..<max(valueStart, trimmedEnd(body.valueEnd))
        switch body.terminator {
        case .endobj(let next):
            objects.append(Object(number: number, generation: generation, value: Data(bytes[valueRange]),
                                  valueRange: valueRange, stream: nil, streamRange: nil))
            return next
        case .nextObject(let headerStart):
            // A missing "endobj": keep the value if it was complete.
            if !valueRange.isEmpty {
                objects.append(Object(number: number, generation: generation, value: Data(bytes[valueRange]),
                                      valueRange: valueRange, stream: nil, streamRange: nil))
            }
            return headerStart
        case .stream(let keywordEnd):
            let value = Data(bytes[valueRange])
            guard let data = streamRange(afterKeyword: keywordEnd, dictionary: latin1(valueRange)) else {
                incomplete.append((number, latin1(valueRange)))
                return bytes.count
            }
            objects.append(Object(number: number, generation: generation, value: value, valueRange: valueRange,
                                  stream: Data(bytes[data.range]), streamRange: data.range))
            return data.next
        case .broken(let resume):
            incomplete.append((number, latin1(valueRange)))
            return resume
        case .truncated:
            incomplete.append((number, latin1(valueRange)))
            return bytes.count
        }
    }

    private enum Terminator {
        case endobj(next: Int)
        case stream(keywordEnd: Int)
        case nextObject(headerStart: Int)
        /// A malformed object; scanning resumes at the given index.
        case broken(resume: Int)
        case truncated
    }

    /// Walks the tokens of an object's body until "endobj", "stream" or the next object's header at the top level.
    private func scanBody(from start: Int) -> (valueEnd: Int, terminator: Terminator) {
        var index = start
        var depth = 0
        var numbers: [Int] = [] // starts of the latest integer tokens, for spotting "N G obj"
        while true {
            index = skipSpace(index)
            guard index < bytes.count else { return (index, .truncated) }
            let byte = bytes[index]
            switch byte {
            case 0x28: // (
                guard let end = literalStringEnd(from: index) else { return (index, .truncated) }
                index = end; numbers = []
            case 0x3C: // <
                if index + 1 < bytes.count, bytes[index + 1] == 0x3C { depth += 1; index += 2 }
                else { index = (find([0x3E], from: index) ?? bytes.count - 1) + 1 }
                numbers = []
            case 0x3E: // >
                if index + 1 < bytes.count, bytes[index + 1] == 0x3E { depth = max(depth - 1, 0); index += 2 } else { index += 1 }
                numbers = []
            case 0x5B: depth += 1; index += 1; numbers = []
            case 0x5D: depth = max(depth - 1, 0); index += 1; numbers = []
            case 0x2F: // /name
                index += 1
                while index < bytes.count, !isDelimiterOrSpace(bytes[index]) { index += 1 }
                numbers = []
            case 0x7B, 0x7D, 0x29: index += 1
            default:
                let tokenStart = index
                while index < bytes.count, !isDelimiterOrSpace(bytes[index]) { index += 1 }
                let token = latin1(tokenStart..<index)
                if token == "endobj" { return (tokenStart, depth == 0 ? .endobj(next: index) : .broken(resume: index)) }
                if token == "stream" { return (tokenStart, depth == 0 ? .stream(keywordEnd: index) : .broken(resume: index)) }
                if token == "obj", numbers.count >= 2 {
                    let header = numbers[numbers.count - 2]
                    return (header, depth == 0 ? .nextObject(headerStart: header) : .broken(resume: header))
                }
                if token == "xref" || token == "trailer" || token == "startxref" {
                    return (tokenStart, depth == 0 ? .nextObject(headerStart: tokenStart) : .broken(resume: tokenStart))
                }
                if Int(token) != nil { numbers.append(tokenStart) } else { numbers = [] }
            }
        }
    }

    /// The data of a stream whose "stream" keyword ends at `keywordEnd`, and where scanning continues.
    private func streamRange(afterKeyword keywordEnd: Int, dictionary: String) -> (range: Range<Int>, next: Int)? {
        var start = keywordEnd
        if start < bytes.count, bytes[start] == 0x0D { start += 1 }
        if start < bytes.count, bytes[start] == 0x0A { start += 1 }
        let endstream = Array("endstream".utf8)
        if let length = Self.directLength(in: dictionary), start + length <= bytes.count {
            let after = skipSpace(start + length)
            if matches(endstream, at: after) { return (start..<start + length, afterEndobj(after + endstream.count)) }
        }
        guard let found = find(endstream, from: start) else { return nil }
        var end = found
        if end > start, bytes[end - 1] == 0x0A { end -= 1 }
        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
        return (start..<end, afterEndobj(found + endstream.count))
    }

    private func afterEndobj(_ index: Int) -> Int {
        let next = skipSpace(index)
        return matches(Array("endobj".utf8), at: next) ? next + 6 : index
    }

    /// Objects packed in object streams (PDF 1.5+), listed right after the stream that holds them.
    private mutating func unpackObjectStreams() {
        var result: [Object] = []
        for object in objects {
            let text = object.text
            guard text.range(of: #"/Type\s*/ObjStm\b"#, options: .regularExpression) != nil, let stream = object.stream else {
                result.append(object)
                continue
            }
            guard let decoded = Self.decode(stream, dictionary: text),
                  let count = Self.integer("N", in: text), let first = Self.integer("First", in: text), first <= decoded.count else {
                unreadableObjectStreams += 1
                continue
            }
            let header = String(decoding: decoded.prefix(first), as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            let pairs = stride(from: 0, to: min(header.count - 1, count * 2), by: 2).map { (header[$0], header[$0 + 1]) }
            for (position, pair) in pairs.enumerated() {
                let start = first + pair.1
                let end = position + 1 < pairs.count ? first + pairs[position + 1].1 : decoded.count
                guard start < end, end <= decoded.count else { continue }
                result.append(Object(number: pair.0, generation: 0, value: decoded.subdata(in: start..<end),
                                     valueRange: nil, stream: nil, streamRange: nil))
            }
        }
        objects = result
    }

    // MARK: Byte helpers

    private func header(endingAt keyword: Int) -> (Int, Int, Int)? {
        var index = keyword - 1
        func spaces() -> Bool {
            let start = index
            while index >= 0, isSpace(bytes[index]) { index -= 1 }
            return index < start
        }
        func digits() -> Int? {
            let end = index
            while index >= 0, bytes[index] >= 0x30, bytes[index] <= 0x39 { index -= 1 }
            guard index < end, end - index <= 10 else { return nil }
            return Int(latin1(index + 1..<end + 1))
        }
        guard spaces(), let generation = digits(), spaces(), let number = digits() else { return nil }
        guard index < 0 || isDelimiterOrSpace(bytes[index]) else { return nil }
        return (number, generation, index + 1)
    }

    private func literalStringEnd(from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case 0x5C: index += 1
            case 0x28: depth += 1
            case 0x29:
                depth -= 1
                if depth == 0 { return index + 1 }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// End of the dictionary, array or token starting at `start`.
    private func valueEnd(from start: Int) -> Int? {
        var index = start, depth = 0
        repeat {
            index = skipSpace(index)
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case 0x28: guard let end = literalStringEnd(from: index) else { return nil }; index = end
            case 0x3C:
                if index + 1 < bytes.count, bytes[index + 1] == 0x3C { depth += 1; index += 2 }
                else { guard let end = find([0x3E], from: index) else { return nil }; index = end + 1 }
            case 0x3E:
                if index + 1 < bytes.count, bytes[index + 1] == 0x3E { depth -= 1; index += 2 } else { index += 1 }
            case 0x5B: depth += 1; index += 1
            case 0x5D: depth -= 1; index += 1
            default:
                index += 1
                while index < bytes.count, !isDelimiterOrSpace(bytes[index]) { index += 1 }
            }
        } while depth > 0
        return index
    }

    private func skipSpace(_ start: Int) -> Int {
        var index = start
        while index < bytes.count {
            if isSpace(bytes[index]) { index += 1 }
            else if bytes[index] == 0x25 { // % comment
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else { break }
        }
        return index
    }

    private func trimmedEnd(_ end: Int) -> Int {
        var index = min(end, bytes.count)
        while index > 0, isSpace(bytes[index - 1]) { index -= 1 }
        return index
    }

    func find(_ pattern: [UInt8], from start: Int) -> Int? {
        Self.find(pattern, in: bytes, from: start)
    }

    static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int, to limit: Int? = nil) -> Int? {
        guard let first = pattern.first else { return nil }
        let end = (limit ?? bytes.count) - pattern.count
        guard start <= end else { return nil }
        var index = max(start, 0)
        while index <= end {
            if bytes[index] == first {
                var matched = true
                for offset in 1..<pattern.count where bytes[index + offset] != pattern[offset] { matched = false; break }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    private func matches(_ pattern: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + pattern.count <= bytes.count else { return false }
        return bytes[index..<index + pattern.count].elementsEqual(pattern)
    }

    private func latin1(_ range: Range<Int>) -> String {
        String(bytes: bytes[range.clamped(to: 0..<bytes.count)], encoding: .isoLatin1) ?? ""
    }

    private func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00 }

    private func isDelimiterOrSpace(_ byte: UInt8) -> Bool {
        isSpace(byte) || byte == 0x28 || byte == 0x29 || byte == 0x3C || byte == 0x3E || byte == 0x5B || byte == 0x5D
            || byte == 0x7B || byte == 0x7D || byte == 0x2F || byte == 0x25
    }

    // MARK: Dictionary text

    static func directLength(in dictionary: String) -> Int? {
        guard let match = dictionary.firstMatch(of: #/\/Length(?![0-9A-Za-z])\s*(\d+)(\s+\d+\s+R)?/#), match.2 == nil else { return nil }
        return Int(match.1)
    }

    static func integer(_ key: String, in dictionary: String) -> Int? {
        guard let range = dictionary.range(of: "/\(key)(?![0-9A-Za-z])\\s*(\\d+)", options: .regularExpression) else { return nil }
        return Int(dictionary[range].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces))
    }

    /// The object number of an indirect reference, e.g. 12 for "/Root 12 0 R".
    static func reference(_ key: String, in dictionary: String) -> Int? {
        guard let range = dictionary.range(of: "/\(key)\\s+(\\d+)\\s+\\d+\\s+R", options: .regularExpression) else { return nil }
        return Int(dictionary[range].dropFirst(key.count + 1).split(whereSeparator: \.isWhitespace).first ?? "")
    }

    /// The raw "/Key value" text for a top-level key of a dictionary, e.g. "/MediaBox [0 0 612 792]".
    static func entry(_ key: String, in dictionary: String) -> String? {
        let characters = Array(dictionary.unicodeScalars)
        let target = Array(("/" + key).unicodeScalars)
        var depth = 0
        var index = 0
        func isDelimiter(_ c: Unicode.Scalar) -> Bool { " \t\r\n\u{0C}\u{0}/<>[]()".unicodeScalars.contains(c) }
        while index < characters.count {
            let c = characters[index]
            if c == "(" {
                var nesting = 0
                while index < characters.count {
                    if characters[index] == "\\" { index += 1 }
                    else if characters[index] == "(" { nesting += 1 }
                    else if characters[index] == ")" { nesting -= 1; if nesting == 0 { break } }
                    index += 1
                }
            } else if c == "<", index + 1 < characters.count, characters[index + 1] == "<" { depth += 1; index += 1 }
            else if c == ">", index + 1 < characters.count, characters[index + 1] == ">" { depth -= 1; index += 1 }
            else if c == "[" { depth += 1 } else if c == "]" { depth -= 1 }
            else if depth == 1, c == "/", index + target.count <= characters.count,
                    Array(characters[index..<index + target.count]) == target,
                    index + target.count == characters.count || isDelimiter(characters[index + target.count]) {
                // Found the key at the top level: its value runs to the next top-level key or the end.
                var end = index + target.count
                var valueDepth = 0
                var started = false
                while end < characters.count {
                    let v = characters[end]
                    if v == "<", end + 1 < characters.count, characters[end + 1] == "<" { valueDepth += 1; end += 2; started = true; continue }
                    if v == ">", end + 1 < characters.count, characters[end + 1] == ">" {
                        if valueDepth == 0 { break }
                        valueDepth -= 1; end += 2
                        if valueDepth == 0 { break }
                        continue
                    }
                    if v == "[" { valueDepth += 1; started = true } else if v == "]" { valueDepth -= 1; if valueDepth == 0 { end += 1; break } }
                    else if v == "/", valueDepth == 0, started { break }
                    else if !" \t\r\n".unicodeScalars.contains(v) { started = true }
                    end += 1
                }
                var scalars = String.UnicodeScalarView()
                scalars.append(contentsOf: characters[index..<end])
                return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            index += 1
        }
        return nil
    }

    static func references(in text: Substring) -> [Int] {
        text.matches(of: #/(\d+)\s+(\d+)\s+R/#).compactMap { Int($0.1) }
    }

    static func hasType(_ type: String, _ text: String) -> Bool {
        text.range(of: "/Type\\s*/\(type)(?![0-9A-Za-z])", options: .regularExpression) != nil
    }

    /// Decodes a Flate (or unfiltered) stream. Nil for other filters and predictors.
    static func decode(_ stream: Data, dictionary: String) -> Data? {
        let filters = dictionary.matches(of: #/\/(FlateDecode|Fl|ASCIIHexDecode|ASCII85Decode|LZWDecode|RunLengthDecode|DCTDecode|JPXDecode|CCITTFaxDecode|JBIG2Decode|Crypt)\b/#).map { String($0.1) }
        if filters.isEmpty { return stream }
        guard filters.allSatisfy({ $0 == "FlateDecode" || $0 == "Fl" }), filters.count == 1,
              dictionary.range(of: #"/Predictor\s*(1[0-5]|2)\b"#, options: .regularExpression) == nil else { return nil }
        return inflate(stream)
    }

    /// Inflates zlib data, keeping whatever decodes before damage.
    static func inflate(_ data: Data) -> Data? {
        var input = [UInt8](data)
        guard input.count > 2 else { return nil }
        // Compression's ZLIB is raw deflate, so drop the RFC 1950 header.
        if input[0] & 0x0F == 8, (UInt16(input[0]) << 8 | UInt16(input[1])) % 31 == 0 { input.removeFirst(2) }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return input.withUnsafeBufferPointer { source -> Data? in
            stream.pointee.src_ptr = source.baseAddress!
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END { return output }
                if status != COMPRESSION_STATUS_OK || produced == 0 { return output.isEmpty ? nil : output }
            }
        }
    }
}

/// What repairing one file did.
struct PDFRepairOutcome: Sendable {
    enum Method: String, Sendable {
        case trimmed, rebuilt, rewritten, redrawn, salvaged

        var label: String {
            switch self {
            case .trimmed: "Removed damaged bytes"
            case .rebuilt: "Rebuilt the file structure"
            case .rewritten: "Rewrote the document"
            case .redrawn: "Redrew page by page"
            case .salvaged: "Recovered images only"
            }
        }
    }

    var methods: [Method] = []
    /// Damage found and fixed, in plain words.
    var fixes: [String] = []
    var pages = 0
    /// The page count the file claimed, when it could be read.
    var expectedPages: Int?
    /// What couldn't be kept.
    var lost: [String] = []

    var damageFound: Bool { !fixes.isEmpty || methods.contains(.redrawn) || methods.contains(.salvaged) }
    var isPartial: Bool { methods.contains(.salvaged) || (expectedPages.map { pages < $0 } ?? false) || !lost.isEmpty }
}

/// Recovers damaged PDFs. Each strategy runs only when the ones before it didn't get every page back:
/// trim junk around the file, rebuild the structure from the objects that survive, rewrite with PDFKit,
/// redraw page by page, and finally salvage embedded JPEG images.
enum PDFRepair {
    static func repair(_ input: URL, to output: URL, progress: (Double) -> Void = { _ in }) throws -> PDFRepairOutcome {
        let original = try Data(contentsOf: input)
        guard !original.isEmpty else { throw ToolError.failed("The file is empty.") }
        var outcome = PDFRepairOutcome()
        let bytes = [UInt8](original)

        // 1. Junk around the file, e.g. an HTML error page or download padding.
        var candidate = original
        if let header = PDFRawFile.find(Array("%PDF-".utf8), in: bytes, from: 0) {
            var end = bytes.count
            // Bytes after the last %%EOF are junk only if they hold no objects: linearized files and
            // cut-off incremental updates have their body there.
            if let eof = lastEOF(in: bytes, from: header),
               PDFRawFile.find(Array("endobj".utf8), in: bytes, from: eof) == nil,
               PDFRawFile.find(Array("stream".utf8), in: bytes, from: eof) == nil,
               bytes[eof...].contains(where: { ![0x20, 0x0A, 0x0D, 0x09, 0x00].contains($0) }) {
                end = eof
                outcome.fixes.append("Removed \(byteString(bytes.count - eof)) of junk after the end of the file.")
            }
            if header > 0 { outcome.fixes.append("Removed \(byteString(header)) of junk before the PDF header.") }
            if header > 0 || end < bytes.count {
                candidate = Data(bytes[header..<end])
                outcome.methods.append(.trimmed)
            }
        }
        progress(0.15)

        if !hasValidXref(candidate) { outcome.fixes.append("The cross-reference table pointed to the wrong places.") }
        // The page count Quartz reads from the page tree, when it can open the file.
        var expected = CGDataProvider(data: candidate as CFData).flatMap { CGPDFDocument($0) }.map(\.numberOfPages).flatMap { $0 > 0 ? $0 : nil }
        var readable = readablePages(candidate)
        var raw: PDFRawFile?

        // 2. Rebuild from the surviving objects when pages are missing. Healthy files are left alone:
        // their leftover objects can include pages deleted in a later save.
        if readable == 0 || (expected.map { readable < $0 } ?? false) {
            let scanned = PDFRawFile(data: candidate)
            raw = scanned
            expected = expected ?? claimedPageCount(scanned) ?? foundPageCount(scanned)
            if let rebuilt = rebuild(scanned), readablePages(rebuilt.data) > readable {
                candidate = rebuilt.data
                readable = readablePages(candidate)
                outcome.methods.append(.rebuilt)
                outcome.fixes += rebuilt.fixes
            }
        }
        progress(0.35)
        outcome.expectedPages = expected

        if readable > 0 {
            // 3. Rewrite with PDFKit, which keeps links, bookmarks, forms and comments.
            if let document = PDFDocument(data: candidate), document.isLocked {
                try candidate.write(to: output)
                outcome.pages = readable
                outcome.lost.append("It's still password-protected. Unlock it with Remove PDF Password.")
            } else if let rewritten = rewrite(candidate, pages: readable) {
                try rewritten.write(to: output)
                outcome.methods.append(.rewritten)
                outcome.pages = readable
            } else {
                // 4. Redraw what each page shows into a fresh file.
                let (data, drawn, skipped) = try redraw(candidate, progress: { progress(0.35 + $0 * 0.6) })
                guard drawn > 0 else { throw ToolError.failed("No pages could be recovered.") }
                try data.write(to: output)
                outcome.methods.append(.redrawn)
                outcome.pages = drawn
                outcome.lost.append("Links, form fields and comments were dropped.")
                if !skipped.isEmpty { outcome.lost.append("Couldn't recover \(skipped.count == 1 ? "page" : "pages") \(PDFOps.rangeString(skipped.map { $0 - 1 })).") }
            }
            if let expected, outcome.pages < expected {
                outcome.lost.append("\(expected - outcome.pages) of \(expected) pages couldn't be recovered.")
            } else if outcome.methods.contains(.rebuilt), let raw, raw.incomplete.count > 0 || !hasEOF(raw) {
                outcome.lost.append("The end of the file was missing, so anything stored there is lost.")
            }
        } else {
            // 5. Nothing readable: keep the photos and scans the file contains.
            let images = salvageJPEGs(bytes)
            guard !images.isEmpty else {
                throw ToolError.failed("Nothing could be recovered. The file has no readable pages or images.")
            }
            try writeImagePDF(images, to: output)
            outcome.methods.append(.salvaged)
            outcome.pages = images.count
            outcome.lost.append("Only images could be recovered. Text, fonts and drawings are lost.")
        }
        progress(1)
        if !outcome.damageFound, outcome.methods == [.rewritten] { outcome.expectedPages = nil }
        return outcome
    }

    // MARK: Checks

    static func readablePages(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return 0 }
        if document.isEncrypted, !document.isUnlocked { _ = document.unlockWithPassword("") }
        guard document.numberOfPages > 0 else { return 0 }
        guard document.isUnlocked else { return document.numberOfPages }
        return (1...document.numberOfPages).filter { document.page(at: $0) != nil }.count
    }

    /// The page count the file's page tree claims.
    static func claimedPageCount(_ raw: PDFRawFile) -> Int? {
        raw.latest.values.map(\.text).filter { PDFRawFile.hasType("Pages", $0) && PDFRawFile.reference("Parent", in: $0) == nil }
            .compactMap { PDFRawFile.integer("Count", in: $0) }.max()
    }

    /// Page objects in the file, complete or cut off.
    static func foundPageCount(_ raw: PDFRawFile) -> Int? {
        let numbers = Set(raw.latest.values.filter { PDFRawFile.hasType("Page", $0.text) }.map(\.number)
            + raw.incomplete.filter { PDFRawFile.hasType("Page", $0.text) }.map(\.number))
        return numbers.isEmpty ? nil : numbers.count
    }

    static func hasValidXref(_ data: Data) -> Bool {
        let tail = String(data: data.suffix(2048), encoding: .isoLatin1) ?? ""
        guard let match = tail.matches(of: #/startxref\s+(\d+)/#).last, let offset = Int(match.1), offset < data.count else { return false }
        let bytes = [UInt8](data[offset..<min(offset + 64, data.count)])
        let start = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        if start.hasPrefix("xref") {
            // Spot-check that in-use entries point at their objects.
            let table = String(data: data[offset..<min(offset + 20 * 200 + 64, data.count)], encoding: .isoLatin1) ?? ""
            var checked = 0
            for section in table.matches(of: #/(\d+) (\d+)\s*\n((?:\d{10} \d{5} [nf]\s*\r?\n?)+)/#) {
                var number = Int(section.1) ?? 0
                for entry in section.3.split(whereSeparator: \.isNewline) {
                    let parts = entry.split(separator: " ")
                    defer { number += 1 }
                    guard parts.count >= 3, parts[2].hasPrefix("n"), let position = Int(parts[0]), checked < 50 else { continue }
                    checked += 1
                    guard position < data.count,
                          let head = String(data: data[position..<min(position + 24, data.count)], encoding: .isoLatin1),
                          head.hasPrefix("\(number) ") else { return false }
                }
            }
            return true
        }
        return start.range(of: #"^\d+\s+\d+\s+obj"#, options: .regularExpression) != nil
    }

    private static func lastEOF(in bytes: [UInt8], from start: Int) -> Int? {
        let marker = Array("%%EOF".utf8)
        var index = bytes.count - marker.count
        while index >= start {
            if bytes[index] == 0x25, bytes[index..<index + marker.count].elementsEqual(marker) { return index + marker.count }
            index -= 1
        }
        return nil
    }

    private static func hasEOF(_ raw: PDFRawFile) -> Bool { lastEOF(in: raw.bytes, from: 0) != nil }

    // MARK: Rebuild

    /// Writes the surviving objects into a new file with a fresh cross-reference table, catalog and page list.
    static func rebuild(_ raw: PDFRawFile) -> (data: Data, fixes: [String])? {
        var fixes: [String] = []
        var latest = raw.latest
        // Old cross-reference streams, object streams (unpacked already) and linearization hints no longer apply.
        latest = latest.filter { _, object in
            let text = object.text
            return !PDFRawFile.hasType("XRef", text) && !PDFRawFile.hasType("ObjStm", text)
                && text.range(of: "/Linearized", options: .literal) == nil
        }
        guard !latest.isEmpty else { return nil }
        if !raw.incomplete.isEmpty { fixes.append("Dropped \(raw.incomplete.count == 1 ? "an incomplete object" : "\(raw.incomplete.count) incomplete objects") at the end of the file.") }
        if raw.unreadableObjectStreams > 0 { fixes.append("Skipped \(raw.unreadableObjectStreams) unreadable compressed object group\(raw.unreadableObjectStreams == 1 ? "" : "s").") }
        var nextNumber = (latest.keys.max() ?? 0) + 1

        // The catalog the trailer names, else the last one found, else a new one.
        let trailerTexts = Array(raw.trailers.map(\.text).reversed()) + Array(raw.objects.map(\.text).filter { PDFRawFile.hasType("XRef", $0) }.reversed())
        var root = trailerTexts.lazy.compactMap { PDFRawFile.reference("Root", in: $0) }.first { latest[$0].map { PDFRawFile.hasType("Catalog", $0.text) } ?? false }
        if root == nil { root = raw.objects.last { PDFRawFile.hasType("Catalog", $0.text) && latest[$0.number] != nil }?.number }

        // Pages in page-tree order, then any the tree lost track of.
        var ordered: [Int] = []
        var treeIsSound = true
        var visited = Set<Int>()
        func walk(_ number: Int, depth: Int) {
            guard depth < 64, visited.insert(number).inserted else { treeIsSound = false; return }
            guard let node = latest[number] else { treeIsSound = false; return }
            let text = node.text
            if PDFRawFile.hasType("Pages", text) {
                guard let kids = text.firstMatch(of: #/\/Kids\s*\[([^\]]*)\]/#) else { treeIsSound = false; return }
                for kid in PDFRawFile.references(in: kids.1) { walk(kid, depth: depth + 1) }
                if let count = PDFRawFile.integer("Count", in: text), depth == 0, count != ordered.count { treeIsSound = false }
            } else if PDFRawFile.hasType("Page", text) {
                ordered.append(number)
            } else { treeIsSound = false }
        }
        let treeRoot = root.flatMap { latest[$0] }.flatMap { PDFRawFile.reference("Pages", in: $0.text) }
        if let treeRoot { walk(treeRoot, depth: 0) } else { treeIsSound = false }
        let pageObjects = raw.objects.filter { PDFRawFile.hasType("Page", $0.text) && latest[$0.number] != nil }.map(\.number)
        var seen = Set(ordered)
        for number in pageObjects where seen.insert(number).inserted { ordered.append(number); treeIsSound = false }
        guard !ordered.isEmpty else { return nil }

        var replacements: [Int: String] = [:]
        if !treeIsSound || treeRoot == nil {
            // The parent most pages point to, so their /Parent links resolve again.
            let parents = ordered.compactMap { latest[$0].flatMap { PDFRawFile.reference("Parent", in: $0.text) } }
            // Reuse it only if it's missing: a surviving node is an intermediate one with its own parent.
            let commonParent = Dictionary(grouping: parents, by: { $0 })
                .max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }
                .map(\.key).flatMap { latest[$0] == nil ? $0 : nil }
            let number: Int
            if let existing = treeRoot ?? commonParent { number = existing } else { number = nextNumber; nextNumber += 1 }
            let old = latest[number]?.text ?? ""
            let mediaBox = old.firstMatch(of: #/\/MediaBox\s*\[[^\]]*\]/#).map { String($0.0) }
                ?? ordered.lazy.compactMap { latest[$0]?.text.firstMatch(of: #/\/MediaBox\s*\[[^\]]*\]/#).map { String($0.0) } }.first
                ?? "/MediaBox [0 0 612 792]"
            let resources = old.firstMatch(of: #/\/Resources\s+\d+\s+\d+\s+R/#).map { " " + $0.0 } ?? ""
            replacements[number] = "<< /Type /Pages /Kids [\(ordered.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(ordered.count) \(mediaBox)\(resources) >>"
            // Viewers reject pages whose /Parent isn't the node listing them, so point every page at the
            // new root, copying what it inherited from ancestors that will no longer be in its chain.
            for page in ordered {
                guard let text = latest[page]?.text, PDFRawFile.reference("Parent", in: text) != number else { continue }
                var inherited = ""
                var ancestor = PDFRawFile.reference("Parent", in: text)
                var depth = 0
                while let current = ancestor, depth < 32, let node = latest[current]?.text {
                    for key in ["Resources", "MediaBox", "CropBox", "Rotate"] where PDFRawFile.entry(key, in: text) == nil && PDFRawFile.entry(key, in: inherited) == nil {
                        if let entry = PDFRawFile.entry(key, in: node) { inherited += " " + entry }
                    }
                    ancestor = PDFRawFile.reference("Parent", in: node)
                    depth += 1
                }
                var updated = text.replacingOccurrences(of: #"/Parent\s+\d+\s+\d+\s+R"#, with: "/Parent \(number) 0 R", options: .regularExpression)
                if PDFRawFile.reference("Parent", in: updated) == nil { inherited += " /Parent \(number) 0 R" }
                if !inherited.isEmpty, let close = updated.range(of: ">>", options: .backwards) {
                    updated.insert(contentsOf: inherited + " ", at: close.lowerBound)
                }
                replacements[page] = updated
            }
            fixes.append("Rebuilt the list of pages.")
            if let root, let catalog = latest[root] {
                if PDFRawFile.reference("Pages", in: catalog.text) != number {
                    replacements[root] = catalog.text.replacingOccurrences(of: #"/Pages\s+\d+\s+\d+\s+R"#, with: "/Pages \(number) 0 R", options: .regularExpression)
                    if replacements[root] == catalog.text { replacements[root] = "<< /Type /Catalog /Pages \(number) 0 R >>" }
                }
            } else {
                let catalog = nextNumber
                nextNumber += 1
                replacements[catalog] = "<< /Type /Catalog /Pages \(number) 0 R >>"
                root = catalog
                fixes.append("Recreated the document catalog.")
            }
        }
        guard let root else { return nil }
        fixes.append("Wrote a new cross-reference table.")

        var output = Data("%PDF-1.7\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int: (offset: Int, generation: Int)] = [:]
        let numbers = Set(latest.keys).union(replacements.keys).sorted()
        for number in numbers {
            let object = latest[number]
            let generation = replacements[number] == nil ? (object?.generation ?? 0) : 0
            offsets[number] = (output.count, generation)
            output += Data("\(number) \(generation) obj\n".utf8)
            if let replacement = replacements[number] {
                output += Data(replacement.utf8)
            } else if let object, let stream = object.stream {
                var dictionary = object.text
                let length = "/Length \(stream.count)"
                if let range = dictionary.range(of: #"/Length(?![0-9A-Za-z])\s*\d+(\s+\d+\s+R)?"#, options: .regularExpression) {
                    dictionary.replaceSubrange(range, with: length)
                } else if let open = dictionary.range(of: "<<") {
                    dictionary.insert(contentsOf: " \(length) ", at: open.upperBound)
                }
                output += dictionary.data(using: .isoLatin1) ?? object.value
                output += Data("\nstream\n".utf8) + stream + Data("\nendstream".utf8)
            } else if let object {
                output += object.value
            }
            output += Data("\nendobj\n".utf8)
        }
        let size = (numbers.last ?? 0) + 1
        let xref = output.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for number in 1..<max(size, 1) {
            if let entry = offsets[number] {
                table += String(format: "%010d %05d n \n", entry.offset, entry.generation)
            } else {
                table += "0000000000 00001 f \n"
            }
        }
        var trailer = "/Size \(size) /Root \(root) 0 R"
        if let info = trailerTexts.lazy.compactMap({ PDFRawFile.reference("Info", in: $0) }).first(where: { latest[$0] != nil }) {
            trailer += " /Info \(info) 0 R"
        }
        if let encrypt = trailerTexts.lazy.compactMap({ PDFRawFile.reference("Encrypt", in: $0) }).first {
            trailer += " /Encrypt \(encrypt) 0 R"
        }
        if let id = trailerTexts.lazy.compactMap({ $0.firstMatch(of: #/\/ID\s*\[[^\]]*\]/#).map { String($0.0) } }).first {
            trailer += " " + id
        }
        table += "trailer\n<< \(trailer) >>\nstartxref\n\(xref)\n%%EOF\n"
        output += Data(table.utf8)
        return (output, fixes)
    }

    // MARK: Writing

    /// PDFKit's copy of the document, if it reads back with every page.
    private static func rewrite(_ data: Data, pages: Int) -> Data? {
        guard let document = PDFDocument(data: data), document.pageCount >= pages,
              (0..<document.pageCount).allSatisfy({ document.page(at: $0)?.pageRef != nil }) else { return nil }
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.producerAttribute] = "Toolbox"
        document.documentAttributes = attributes
        guard let output = document.dataRepresentation(), readablePages(output) >= pages,
              PDFDocument(data: output)?.pageCount == document.pageCount else { return nil }
        return output
    }

    /// Draws every readable page into a new file. Returns the file, pages drawn and 1-based pages skipped.
    private static func redraw(_ data: Data, progress: (Double) -> Void) throws -> (Data, Int, [Int]) {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw ToolError.failed("The pages couldn't be read.")
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator as String: "Toolbox"] as CFDictionary) else {
            throw ToolError.failed("Couldn't create the repaired PDF.")
        }
        var drawn = 0
        var skipped: [Int] = []
        for number in 1...max(document.numberOfPages, 1) {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { skipped.append(number); continue }
            let crop = page.getBoxRect(.cropBox)
            guard !crop.isNull, !crop.isInfinite, crop.width >= 1, crop.height >= 1, crop.width < 20_000, crop.height < 20_000 else {
                skipped.append(number); continue
            }
            let quarterTurns = ((Int(page.rotationAngle) % 360 + 360) % 360) / 90
            var box = CGRect(origin: .zero, size: quarterTurns % 2 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width))
            context.beginPDFPage(PDFOps.pageInfo(mediaBox: &box))
            context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            context.clip(to: crop)
            context.drawPDFPage(page)
            context.endPDFPage()
            drawn += 1
            progress(Double(number) / Double(document.numberOfPages))
        }
        context.closePDF()
        return (output as Data, drawn, skipped)
    }

    // MARK: Image salvage

    /// Complete or partly readable JPEGs found anywhere in the bytes, in file order.
    static func salvageJPEGs(_ bytes: [UInt8]) -> [Data] {
        var images: [Data] = []
        var index = 0
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF, bytes[index + 1] == 0xD8, bytes[index + 2] == 0xFF else { index += 1; continue }
            let end = PDFJPEG.end(of: bytes, from: index) ?? bytes.count
            let candidate = Data(bytes[index..<end])
            if let source = CGImageSourceCreateWithData(candidate as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width >= 8, image.height >= 8 {
                images.append(candidate)
                index = end
            } else {
                index += 3
            }
        }
        return images
    }

    private static func writeImagePDF(_ images: [Data], to url: URL) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextCreator as String: "Toolbox"] as CFDictionary) else {
            throw ToolError.failed("Couldn't create “\(url.lastPathComponent)”.")
        }
        for data in images {
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                    ?? CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { continue }
            let properties = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
            let dpi = max(properties?[kCGImagePropertyDPIWidth] as? Double ?? 72, 72)
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
            context.beginPDFPage(PDFOps.pageInfo(mediaBox: &box))
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func byteString(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// JPEG structure helpers for salvaging images and removing their metadata.
enum PDFJPEG {
    /// Index just past the image's end marker, or nil if the data ends first.
    static func end(of bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 2
        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }
            if marker == 0xD9 { return index + 2 }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            guard index + 3 < bytes.count else { return nil }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { return nil }
            index += 2 + length
            if marker == 0xDA {
                // Entropy-coded data runs to the next marker that isn't a stuffed byte or restart.
                while index + 1 < bytes.count {
                    if bytes[index] == 0xFF, bytes[index + 1] != 0x00, !(0xD0...0xD7).contains(bytes[index + 1]) { break }
                    index += 1
                }
            }
        }
        return nil
    }

    /// Blanks EXIF, XMP, IPTC and comment segments in place, so the image keeps its size and pixels.
    /// Returns whether anything changed.
    @discardableResult
    static func scrubMetadata(_ bytes: inout [UInt8]) -> Bool {
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        var changed = false
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { break }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }
            if marker == 0xDA || marker == 0xD9 { break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { break }
            // Keep JFIF (APP0), ICC color profiles (APP2) and Adobe color info (APP14).
            let isMetadata = marker == 0xFE || ((0xE1...0xEF).contains(marker) && marker != 0xE2 && marker != 0xEE)
            if isMetadata, bytes[(index + 4)..<(index + 2 + length)].contains(where: { $0 != 0 }) {
                for position in (index + 4)..<(index + 2 + length) { bytes[position] = 0 }
                changed = true
            }
            index += 2 + length
        }
        return changed
    }
}
