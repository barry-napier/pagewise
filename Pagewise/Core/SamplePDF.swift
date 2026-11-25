#if DEBUG
import AppKit
import CoreGraphics

/// A made-up five-page lease for tests. Page 4 has a table. Page 5 is a
/// picture of text with no text layer, like a scan.
enum SamplePDF {
    static let filler = "The parties agree to act in good faith and to keep each other informed of anything that affects the property. Notices under this lease must be in writing. This lease is governed by the laws of Ireland."

    static let pages: [[String]] = [
        ["Residential Lease Agreement",
         "This lease is between Northwind Properties Ltd (the landlord) and Jamie Rivera (the tenant) for the flat at 14 Harbour Road, Galway. The lease starts on 1 March 2026 and runs for twelve months.",
         filler],
        ["Rent",
         "The rent is €1,450 per month, due on the first day of each month by bank transfer. A late fee of €40 applies if rent is more than five days late.",
         "The landlord may review the rent once a year, with at least 90 days of notice before any change.",
         filler],
        ["Deposit and ending the lease",
         "The tenant pays a deposit of €2,900 before moving in. The landlord returns the deposit within 21 days after the lease ends, minus the cost of any damage.",
         "Either party may end this lease by giving 60 days of written notice to the other party.",
         filler],
        ["Bills and services",
         "The table below shows who pays for each service and the expected monthly cost."],
    ]

    static let table = [
        ["Service", "Paid by", "Monthly estimate"],
        ["Electricity", "Tenant", "€80"],
        ["Water", "Landlord", "€0"],
        ["Internet", "Tenant", "€35"],
        ["Bin collection", "Landlord", "€15"],
    ]

    static let scannedText = [
        "Pets",
        "Pets are allowed with written permission from the landlord.",
        "A cat or a small dog is fine. The tenant pays for any damage a pet causes.",
    ]

    static func write(to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for (index, paragraphs) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            draw(paragraphs, in: ctx, box: box)
            if index == 3 { drawTable(in: ctx, top: 560) }
            ctx.endPDFPage()
        }
        // The "scanned" page: text drawn into a picture first.
        ctx.beginPDFPage(nil)
        if let image = picture(of: scannedText, size: box.size) { ctx.draw(image, in: box) }
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private static func draw(_ paragraphs: [String], in ctx: CGContext, box: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var top = box.height - 72
        for (index, text) in paragraphs.enumerated() {
            let font = index == 0 ? NSFont.boldSystemFont(ofSize: 20) : NSFont.systemFont(ofSize: 12)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let string = NSAttributedString(string: text, attributes: attributes)
            let height = string.boundingRect(with: CGSize(width: box.width - 144, height: 1000), options: .usesLineFragmentOrigin).height
            string.draw(with: CGRect(x: 72, y: top - height, width: box.width - 144, height: height), options: .usesLineFragmentOrigin)
            top -= height + 16
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawTable(in ctx: CGContext, top: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let widths: [CGFloat] = [170, 140, 150]
        let rowHeight: CGFloat = 28
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1)
        for (row, cells) in table.enumerated() {
            var x: CGFloat = 72
            let y = top - CGFloat(row + 1) * rowHeight
            for (column, cell) in cells.enumerated() {
                ctx.stroke(CGRect(x: x, y: y, width: widths[column], height: rowHeight))
                let font = row == 0 ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
                (cell as NSString).draw(at: CGPoint(x: x + 8, y: y + 8), withAttributes: [.font: font, .foregroundColor: NSColor.black])
                x += widths[column]
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func picture(of lines: [String], size: CGSize) -> CGImage? {
        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        draw(lines, in: ctx, box: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
}
#endif
