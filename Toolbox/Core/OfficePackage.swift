import Foundation
import PDFKit

/// Small, standards-based Office exporters for PDF contents. Office imports use LibreOffice.
enum OfficePackage {
    static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let typeNS = "http://schemas.openxmlformats.org/package/2006/content-types"
    static func relationship(_ id: String, _ type: String, _ target: String) -> String {
        "<Relationship Id=\"\(id)\" Type=\"\(officeRel + type)\" Target=\"\(target)\"/>"
    }
    static func relationships(_ content: String) -> String { "<?xml version=\"1.0\"?><Relationships xmlns=\"\(relNS)\">\(content)</Relationships>" }
    static func override(_ part: String, _ type: String) -> String {
        "<Override PartName=\"/\(part)\" ContentType=\"application/vnd.openxmlformats-officedocument.\(type)+xml\"/>"
    }
    static func write(_ text: String, at name: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    static func root(in scratch: URL) throws -> URL {
        let url = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func types(_ content: String, images: Bool = false) -> String {
        "<?xml version=\"1.0\"?><Types xmlns=\"\(typeNS)\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" + (images ? "<Default Extension=\"png\" ContentType=\"image/png\"/>" : "") + content + "</Types>"
    }
    static func writeWorkbook(_ sheets: [(String, [[String]])], to output: URL, scratch: URL) async throws {
        let folder = try root(in: scratch)
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        var sheetList = "", rels = "", contentTypes = override("xl/workbook.xml", "spreadsheetml.sheet.main")
        for (index, sheet) in sheets.enumerated() {
            try Task.checkCancellation()
            let id = index + 1
            sheetList += "<sheet name=\"\(DocumentConverter.xml(String(sheet.0.prefix(31))))\" sheetId=\"\(id)\" r:id=\"rId\(id)\"/>"
            rels += relationship("rId\(id)", "worksheet", "worksheets/sheet\(id).xml")
            contentTypes += override("xl/worksheets/sheet\(id).xml", "spreadsheetml.worksheet")
            let rows = sheet.1.enumerated().map { row, values in
                "<row r=\"\(row + 1)\">" + values.enumerated().map { column, value in
                    let ref = columnName(column) + "\(row + 1)"
                    // Text cells deliberately avoid interpreting untrusted content as formulas.
                    let safeValue = DocumentConverter.xml(String(value.prefix(32767)))
                    return "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(safeValue)</t></is></c>"
                }.joined() + "</row>"
            }.joined()
            try write("<?xml version=\"1.0\"?><worksheet xmlns=\"\(ns)\"><sheetData>\(rows)</sheetData></worksheet>", at: "xl/worksheets/sheet\(id).xml", in: folder)
        }
        try write(types(contentTypes), at: "[Content_Types].xml", in: folder)
        try write(relationships(relationship("rId1", "officeDocument", "xl/workbook.xml")), at: "_rels/.rels", in: folder)
        try write("<?xml version=\"1.0\"?><workbook xmlns=\"\(ns)\" xmlns:r=\"\(officeRel.dropLast())\"><sheets>\(sheetList)</sheets></workbook>", at: "xl/workbook.xml", in: folder)
        try write(relationships(rels), at: "xl/_rels/workbook.xml.rels", in: folder)
        try await ArchiveEngine.zipPackage(folder, to: output)
    }
    static func columnName(_ index: Int) -> String {
        var value = index + 1, name = ""
        while value > 0 { value -= 1; name = String(UnicodeScalar(65 + value % 26)!) + name; value /= 26 }
        return name
    }

    static func writeSlides(_ document: PDFDocument, to output: URL, scratch: URL) async throws {
        let folder = try root(in: scratch)
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let r = String(officeRel.dropLast())
        let width = 9_144_000, height = 6_858_000
        var slides = "", rels = relationship("rIdMaster", "slideMaster", "slideMasters/slideMaster1.xml")
        var contentTypes = override("ppt/presentation.xml", "presentationml.presentation.main")
            + override("ppt/slideMasters/slideMaster1.xml", "presentationml.slideMaster")
            + override("ppt/slideLayouts/slideLayout1.xml", "presentationml.slideLayout")
            + override("ppt/theme/theme1.xml", "theme")
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let image = PDFOps.renderPage(page, scale: 2),
                  let data = PDFOps.encode(image, as: .png, quality: 1, dpi: 144) else { throw ToolError.failed("Couldn't render slide \(index + 1).") }
            let id = index + 1
            let media = folder.appendingPathComponent("ppt/media")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try data.write(to: media.appendingPathComponent("image\(id).png"))
            let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
            let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
            let picture = "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"PDF page \(id)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rIdImage\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\((width-w)/2)\" y=\"\((height-h)/2)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
            try write("<?xml version=\"1.0\"?><p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld><p:spTree>\(group)\(picture)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>", at: "ppt/slides/slide\(id).xml", in: folder)
            try write(relationships(relationship("rIdImage", "image", "../media/image\(id).png") + relationship("rIdLayout", "slideLayout", "../slideLayouts/slideLayout1.xml")), at: "ppt/slides/_rels/slide\(id).xml.rels", in: folder)
            slides += "<p:sldId id=\"\(255 + id)\" r:id=\"rId\(id)\"/>"
            rels += relationship("rId\(id)", "slide", "slides/slide\(id).xml")
            contentTypes += override("ppt/slides/slide\(id).xml", "presentationml.slide")
        }
        try write(types(contentTypes, images: true), at: "[Content_Types].xml", in: folder)
        try write(relationships(relationship("rId1", "officeDocument", "ppt/presentation.xml")), at: "_rels/.rels", in: folder)
        try write("<?xml version=\"1.0\"?><p:presentation xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rIdMaster\"/></p:sldMasterIdLst><p:sldIdLst>\(slides)</p:sldIdLst><p:sldSz cx=\"\(width)\" cy=\"\(height)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>", at: "ppt/presentation.xml", in: folder)
        try write(relationships(rels), at: "ppt/_rels/presentation.xml.rels", in: folder)
        let colorMap = "<p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/>"
        try write("<?xml version=\"1.0\"?><p:sldMaster xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld><p:spTree>\(group)</p:spTree></p:cSld>\(colorMap)<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rIdLayout\"/></p:sldLayoutIdLst><p:txStyles/></p:sldMaster>", at: "ppt/slideMasters/slideMaster1.xml", in: folder)
        try write(relationships(relationship("rIdLayout", "slideLayout", "../slideLayouts/slideLayout1.xml") + relationship("rIdTheme", "theme", "../theme/theme1.xml")), at: "ppt/slideMasters/_rels/slideMaster1.xml.rels", in: folder)
        try write("<?xml version=\"1.0\"?><p:sldLayout xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>", at: "ppt/slideLayouts/slideLayout1.xml", in: folder)
        try write(relationships(relationship("rIdMaster", "slideMaster", "../slideMasters/slideMaster1.xml")), at: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", in: folder)
        let colors = [("dk1","000000"),("lt1","FFFFFF"),("dk2","222222"),("lt2","EEEEEE"),("accent1","EE7722"),("accent2","4488AA"),("accent3","88AA44"),("accent4","AA4488"),("accent5","44AAAA"),("accent6","AA8844"),("hlink","0000FF"),("folHlink","800080")].map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fills = String(repeating: "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>", count: 3)
        let lines = [9525,25400,38100].map { "<a:ln w=\"\($0)\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>" }.joined()
        let effects = String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3)
        try write("<?xml version=\"1.0\"?><a:theme xmlns:a=\"\(a)\" name=\"Toolbox\"><a:themeElements><a:clrScheme name=\"Toolbox\">\(colors)</a:clrScheme><a:fontScheme name=\"Toolbox\"><a:majorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"Toolbox\"><a:fillStyleLst>\(fills)</a:fillStyleLst><a:lnStyleLst>\(lines)</a:lnStyleLst><a:effectStyleLst>\(effects)</a:effectStyleLst><a:bgFillStyleLst>\(fills)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>", at: "ppt/theme/theme1.xml", in: folder)
        try await ArchiveEngine.zipPackage(folder, to: output)
    }
}
