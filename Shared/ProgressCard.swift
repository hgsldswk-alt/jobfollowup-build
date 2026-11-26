import CoreImage
import Foundation
import UIKit

struct ProgressCounts: Equatable {
    let applied: Int
    let interviews: Int
    let offers: Int

    static func month(_ date: Date, jobs: [Application], calendar: Calendar = .current) -> Self {
        guard let period = calendar.dateInterval(of: .month, for: date) else { return Self(applied: 0, interviews: 0, offers: 0) }
        let first = Day(period.start, calendar: calendar)
        let end = Day(period.end, calendar: calendar)
        let applied = jobs.filter { job in job.applied.map { first <= $0 && $0 < end } == true }.count
        func number(_ status: JobStatus) -> Int {
            jobs.filter { job in
                job.events.contains { $0.kind == .status && $0.status == status && $0.date >= period.start && $0.date < period.end }
            }.count
        }
        return Self(applied: applied, interviews: number(.interview), offers: number(.offer))
    }
}

enum CardMilestone: String, Identifiable {
    case interview, offer
    var id: String { rawValue }
    var title: String { L.t("milestone." + rawValue) }
}

struct ProgressCard: Identifiable {
    static let topics = "#jobsearch #jobhunt"
    var id: String { (milestone?.rawValue ?? "month") + month }
    let month: String
    let counts: ProgressCounts?
    var milestone: CardMilestone?
    let downloadURL: URL

    var heading: String { milestone?.title ?? L.t("share.heading") }
    var caption: String {
        if let counts { return L.f("share.caption", month, counts.applied, counts.interviews, counts.offers) + " " + Self.topics }
        return heading + " · " + month + " " + Self.topics
    }

    func png() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let canvas = CGRect(x: 0, y: 0, width: 1080, height: 1350)
        let olive = UIColor(red: 74/255, green: 93/255, blue: 35/255, alpha: 1)
        let paper = UIColor(red: 247/255, green: 244/255, blue: 236/255, alpha: 1)
        let pale = UIColor(red: 230/255, green: 234/255, blue: 215/255, alpha: 1)
        let ink = UIColor(red: 46/255, green: 49/255, blue: 38/255, alpha: 1)
        guard let qr = Self.qr(downloadURL) else { throw JobError.unavailable }
        return UIGraphicsImageRenderer(size: canvas.size, format: format).pngData { context in
            func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
                      weight: UIFont.Weight, color: UIColor, height: CGFloat = 200) {
                (string as NSString).draw(with: CGRect(x: x, y: y, width: width, height: height),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                                          attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                       .foregroundColor: color], context: nil)
            }
            paper.setFill()
            context.fill(canvas)
            olive.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1080, height: 24))
            text(month, x: 74, y: 92, width: 926, size: 38, weight: .medium, color: olive)
            text(heading, x: 70, y: 181, width: 940, size: 84, weight: .bold, color: ink, height: 255)
            pale.setFill()
            UIBezierPath(roundedRect: CGRect(x: 70, y: 471, width: 940, height: 471), cornerRadius: 42).fill()
            if let counts {
                let items = [(counts.applied, "progress.applied"), (counts.interviews, "progress.interviews"), (counts.offers, "progress.offers")]
                for (index, item) in items.enumerated() {
                    let y = CGFloat(516 + 127 * index)
                    text(item.0.formatted(), x: 112, y: y, width: 455, size: 76, weight: .bold, color: olive)
                    text(L.t(item.1), x: 565, y: y + 19, width: 390, size: 42, weight: .semibold, color: ink)
                }
            } else {
                text(L.t("milestone.message"), x: 123, y: 615, width: 810, size: 63, weight: .semibold, color: olive, height: 240)
            }
            let qrRect = CGRect(x: 738, y: 983, width: 267, height: 267)
            UIColor.white.setFill()
            context.fill(qrRect)
            context.cgContext.interpolationQuality = .none
            let size = CGFloat(qr.width)
            let step = floor(qrRect.width / (size + 8))
            let side = step * size
            let inset = floor((qrRect.width - side) / 2)
            UIImage(cgImage: qr).draw(in: CGRect(x: qrRect.minX + inset, y: qrRect.minY + inset, width: side, height: side))
            text(L.t("app.name"), x: 75, y: 1030, width: 635, size: 50, weight: .bold, color: olive)
            text(L.t("share.scan"), x: 76, y: 1100, width: 620, size: 34, weight: .regular, color: ink)
            text(Self.topics, x: 76, y: 1210, width: 640, size: 35, weight: .medium, color: olive)
        }
    }

    static func qr(_ url: URL) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image, from: image.extent.integral)
    }
}
