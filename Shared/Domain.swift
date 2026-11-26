import Foundation

struct Day: Codable, Hashable, Comparable {
    let iso: String

    init(_ date: Date, calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        iso = String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }

    init?(iso: String) {
        self.iso = iso
        guard let date = date(in: Self.utc), Self(date, calendar: Self.utc).iso == iso else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.iso < rhs.iso }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func date(in calendar: Calendar = .current) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    func adding(_ days: Int, calendar: Calendar = .current) -> Day {
        guard let date = date(in: calendar),
              let next = calendar.date(byAdding: .day, value: days, to: date) else { return self }
        return Day(next, calendar: calendar)
    }

    var label: String { date()?.formatted(.dateTime.month(.abbreviated).day().year()) ?? iso }
}

enum JobStatus: String, Codable, CaseIterable, Identifiable {
    case applied, interview, rejected, offer, noReply
    var id: String { rawValue }
    var title: String { L.t("status." + rawValue) }
    var active: Bool { self != .rejected && self != .offer }
    var awaiting: Bool { self == .applied || self == .noReply }
}

struct CadenceTemplate: Codable, Equatable {
    var version = 1
    var type = "follow-up"
    var intervals = [7, 7]
    var valid: Bool {
        version == 1 && type == "follow-up" && (1...5).contains(intervals.count)
            && intervals.allSatisfy { (1...90).contains($0) }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, type, intervals }

    func code() throws -> String {
        guard valid else { throw JobError.badCode }
        let encoded = try JSONEncoder().encode(self).base64EncodedString()
        return "JF1:" + encoded.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ input: String) throws -> Self {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 512, raw.hasPrefix("JF1:") else { throw JobError.badCode }
        let body = String(raw.dropFirst(4))
        guard !body.isEmpty, body.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw JobError.badCode }
        let padded = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
              let value = try? JSONDecoder().decode(Self.self, from: bytes), value.valid else { throw JobError.badCode }
        return value
    }
}

struct FollowUp: Codable, Equatable {
    var manualDate: Day?
    var automatic: Bool?
    var completed = 0
    var lastLogged: Day?
    var intervals = [7, 7]

    func due(for job: Application, calendar: Calendar = .current) -> Day? {
        guard job.active else { return nil }
        if let manualDate { return manualDate }
        guard automatic != false, job.status.awaiting, intervals.indices.contains(completed) else { return nil }
        let anchor = completed == 0 ? job.applied : lastLogged
        return anchor?.adding(intervals[completed], calendar: calendar)
    }
}

struct StatusEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case created, status, followUp, archived, restored, imported }
    var id = UUID()
    var kind: Kind
    var date: Date
    var status: JobStatus?
    var localDay: Day?
    var title: String {
        if kind == .status, let status { return L.f("event.changed", status.title) }
        return L.t("event." + kind.rawValue)
    }
}

struct Application: Codable, Equatable, Identifiable {
    var id = UUID()
    var company = ""
    var role = ""
    var source = ""
    var applied: Day? = Day(Date())
    var status: JobStatus = .applied
    var archived = false
    var url = ""
    var notes = ""
    var excerpt = ""
    var positionID = ""
    var location = ""
    var follow = FollowUp()
    var events: [StatusEvent] = []
    var active: Bool { !archived && status.active }
    var sourceLabel: String {
        if source.isEmpty { return L.t("source.manual") }
        if source == "@website" { return L.t("source.website") }
        if source == "@email" { return L.t("source.email") }
        return source
    }
    var appliedLabel: String { applied?.label ?? L.t("date.unknown") }
    var due: Day? { follow.due(for: self) }
    var requiredFilled: Bool { !company.trimmed.isEmpty && !role.trimmed.isEmpty }
    mutating func trimFields() {
        company = company.trimmed
        role = role.trimmed
        source = source.trimmed
        url = url.trimmed
        positionID = positionID.trimmed
        location = location.trimmed
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct Entitlement: Codable, Equatable {
    var firstOpen = Date()
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let start = proStartedAt ?? firstOpen
        return min(start, trialClaimedAt ?? start)
    }
    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }
    func hasPro(at now: Date) -> Bool {
        Launch.freePeriod || purchasedPro || (now >= trialStart && now < trialEnd)
    }
    mutating func verifiedTrial(_ originalDate: Date) {
        trialClaimedAt = min(trialClaimedAt ?? originalDate, originalDate)
    }
}

struct JobSettings: Codable, Equatable {
    var reminders = false
    var reminderHour = 9
    var reminderMinute = 0
    var widgetNames = true
    var cadence = CadenceTemplate()
}

struct JobState: Codable, Equatable {
    var jobs: [Application] = []
    var entitlement = Entitlement()
    var settings = JobSettings()
    var reviewedVersions: [String] = []
    var trialNoticeSeen = false

    func activeCount() -> Int { jobs.lazy.filter(\.active).count }
    func ordered() -> [Application] {
        jobs.sorted {
            switch ($0.applied, $1.applied) {
            case (let lhs?, let rhs?) where lhs != rhs: return lhs > rhs
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    func due(on day: Day, calendar: Calendar = .current) -> [Application] {
        jobs.compactMap { job -> (Day, Application)? in
            guard let due = job.follow.due(for: job, calendar: calendar), due <= day else { return nil }
            return (due, job)
        }.sorted {
            $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.id.uuidString < $1.1.id.uuidString
        }.map(\.1)
    }

    func first(_ status: JobStatus) -> Date? {
        jobs.lazy.flatMap(\.events).filter { $0.kind == .status && $0.status == status }.map(\.date).min()
    }

    func canRequestReview(version: String) -> Bool {
        guard first(.interview) != nil, !reviewedVersions.contains(version) else { return false }
        let activity = jobs.lazy.flatMap(\.events).filter { [.created, .status, .followUp].contains($0.kind) }
        return Set(activity.map { $0.localDay ?? Day($0.date) }).count >= 3
    }
}

enum JobError: Error {
    case unavailable, invalidFields, duplicate, cap, requiresPro, changed, badCode, badCSV, cancelled, store

    var message: String {
        switch self {
        case .unavailable: return L.t("error.unavailable")
        case .invalidFields: return L.t("error.fields")
        case .duplicate: return L.t("error.duplicate")
        case .cap: return L.t("error.cap")
        case .requiresPro: return L.t("error.pro")
        case .changed: return L.t("error.changed")
        case .badCode: return L.t("error.code")
        case .badCSV: return L.t("error.csv")
        case .cancelled: return L.t("error.cancelled")
        case .store: return L.t("error.store")
        }
    }
}

func message(for error: Error) -> String { (error as? JobError ?? .unavailable).message }
