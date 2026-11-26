import Foundation

enum CSVField: String, CaseIterable, Identifiable {
    case company = "Company", role = "Role", source = "Source", applied = "Applied Date", status = "Status"
    case followUp = "Follow-up Date", url = "URL", notes = "Notes", excerpt = "Job Excerpt"
    case archived = "Archived", positionID = "Position ID", location = "Location", id = "ID"
    case manual = "Manual Follow-up Date", last = "Last Follow-up Date", completed = "Follow-ups Logged", cadence = "Cadence Days"
    case automatic = "Automatic Follow-up"

    var id: String { rawValue }
    var title: String { L.t("csv.field." + key) }
    var key: String {
        switch self {
        case .company: return "company"
        case .role: return "role"
        case .source: return "source"
        case .applied: return "applied"
        case .status: return "status"
        case .followUp: return "followUp"
        case .url: return "url"
        case .notes: return "notes"
        case .excerpt: return "excerpt"
        case .archived: return "archived"
        case .positionID: return "positionID"
        case .location: return "location"
        case .id: return "id"
        case .manual: return "manual"
        case .last: return "last"
        case .completed: return "completed"
        case .cadence: return "cadence"
        case .automatic: return "automatic"
        }
    }

    var aliases: [String] {
        switch self {
        case .company: return ["employer", "organization", "company name", "公司", "公司名称", "公司名稱", "企業", "企业"]
        case .role: return ["job", "position", "job title", "title", "职位", "職位", "岗位", "崗位", "職缺"]
        case .source: return ["platform", "来源", "來源", "平台"]
        case .applied: return ["date", "application date", "date applied", "投递日期", "投遞日期", "申请日期", "申請日期"]
        case .status: return ["stage", "状态", "狀態", "进度", "進度"]
        case .followUp: return ["follow up", "next follow-up", "跟进日期", "跟進日期", "提醒日期"]
        case .url: return ["link", "job url", "链接", "連結", "網址", "网址"]
        case .notes: return ["note", "comments", "备注", "備註", "笔记", "筆記"]
        case .excerpt: return ["description", "job description", "招聘原文", "职位描述", "職缺描述"]
        case .archived: return ["archive", "归档", "封存", "歸檔"]
        case .positionID: return ["job id", "岗位编号", "職缺編號", "職位編號"]
        case .location: return ["地点", "地點", "工作地点", "工作地點"]
        default: return []
        }
    }
}

enum CSVProblem: String, Equatable {
    case fields, date, ambiguousDate, status, archive, schedule
    var title: String { L.t("csv.problem." + rawValue) }
}

struct CSVRow: Identifiable {
    var id: Int
    var job: Application
    var problems: [CSVProblem] = []
    var rawValues = ""
    var offsetError = false
}

struct CSVPreviewRow: Identifiable {
    enum Kind: String, Equatable {
        case new, invalid, duplicate, conflict
        var title: String { L.t("csv.row." + rawValue) }
    }
    var id: Int { row.id }
    var row: CSVRow
    var kind: Kind
    var existing: Application?
}

struct CSVImport {
    let headers: [String]
    let records: [[String]]
    let portable: Bool
    var mapping: [CSVField: Int]

    init(_ data: Data) throws {
        guard data.count <= 32 * 1024 * 1024, let raw = String(data: data, encoding: .utf8) else { throw JobError.badCSV }
        let rows = try JobCSV.parse(raw)
        guard let headers = rows.first, !headers.allSatisfy({ $0.trimmed.isEmpty }) else { throw JobError.badCSV }
        self.headers = headers
        records = Array(rows.dropFirst())
        portable = headers.first == "JobFollowUp CSV v1"
        var mapping: [CSVField: Int] = [:]
        for field in CSVField.allCases {
            let keys = Set(([field.rawValue] + field.aliases).map(JobMatching.normalize))
            mapping[field] = headers.firstIndex { keys.contains(JobMatching.normalize($0)) }
        }
        self.mapping = mapping
    }

    var hasRequiredColumns: Bool { mapping[.company] != nil && mapping[.role] != nil && mapping[.company] != mapping[.role] }

    func row(at offset: Int, cadence: CadenceTemplate) -> CSVRow {
        let record = records[offset]
        func value(_ field: CSVField) -> String {
            guard let index = mapping[field], record.indices.contains(index) else { return "" }
            return portable ? JobCSV.unescape(record[index]) : record[index]
        }
        let uuid = UUID(uuidString: value(.id).trimmed) ?? UUID()
        var job = Application(id: uuid)
        job.company = value(.company)
        job.role = value(.role)
        job.source = value(.source)
        job.url = value(.url)
        job.notes = value(.notes)
        job.excerpt = value(.excerpt)
        job.positionID = value(.positionID)
        if job.positionID.trimmed.isEmpty { job.positionID = JobMatching.positionID(job.url) ?? "" }
        job.location = value(.location)
        job.trimFields()
        var row = CSVRow(id: offset, job: job)
        guard !record.allSatisfy({ $0.trimmed.isEmpty }) else { return row }
        if !job.requiredFilled || !hasRequiredColumns { row.problems.append(.fields) }
        row.offsetError = record.count > headers.count
        let dates: [(CSVField, WritableKeyPath<Application, Day?>)] = [
            (.applied, \.applied), (portable ? .manual : .followUp, \.follow.manualDate), (.last, \.follow.lastLogged)
        ]
        for (field, key) in dates {
            let text = value(field).trimmed
            job[keyPath: key] = JobCSV.day(text)
            if !text.isEmpty && job[keyPath: key] == nil {
                let problem: CSVProblem = JobCSV.isAmbiguous(text) ? .ambiguousDate : .date
                if !row.problems.contains(problem) { row.problems.append(problem) }
            }
        }
        if let status = JobCSV.status(value(.status)) { job.status = status } else { row.problems.append(.status) }
        switch value(.archived).trimmed.lowercased() {
        case "1", "true", "yes", "是": job.archived = true
        case "", "0", "false", "no", "否": break
        default: row.problems.append(.archive)
        }
        job.follow.intervals = cadence.intervals
        if portable {
            let encoded = value(.cadence)
            let parts = encoded.split(separator: ";", omittingEmptySubsequences: false)
            let intervals = parts.compactMap { Int($0) }
            let completed = Int(value(.completed))
            let template = CadenceTemplate(intervals: intervals)
            if template.valid, intervals.count == parts.count, let completed, (0...1_000_000).contains(completed) {
                job.follow.intervals = intervals
                job.follow.completed = completed
            } else { row.problems.append(.schedule) }
            if value(.automatic) == "0" { job.follow.automatic = false }
        }
        row.job = job
        row.rawValues = [value(.applied), value(.status), value(.followUp), value(.archived)].filter { !$0.isEmpty }.joined(separator: " · ")
        return row
    }

    func preview(state: JobState, corrections: [Int: Application], skipping: Set<Int>) -> [CSVPreviewRow] {
        var seen: [Application] = []
        var identities: [UUID: Int] = [:]
        var matchedKeys: [JobMatching.Key: Int] = [:]
        func remember(_ job: Application, keys: [JobMatching.Key]) {
            let index = seen.count
            if identities[job.id] == nil { identities[job.id] = index }
            for key in keys where matchedKeys[key] == nil { matchedKeys[key] = index }
            seen.append(job)
        }
        for job in state.jobs { remember(job, keys: JobMatching.keys(job)) }
        var touched = Set<UUID>()
        return records.indices.compactMap { index in
            guard !skipping.contains(index), !records[index].allSatisfy({ $0.trimmed.isEmpty }) else { return nil }
            var row = row(at: index, cadence: state.settings.cadence)
            if let corrected = corrections[index] {
                row.job = corrected
                row.problems = corrected.requiredFilled ? [] : [.fields]
                row.offsetError = false
            }
            guard row.problems.isEmpty, !row.offsetError else { return CSVPreviewRow(row: row, kind: .invalid) }
            let keys = JobMatching.keys(row.job)
            if let match = identities[row.job.id] ?? keys.compactMap({ matchedKeys[$0] }).min() {
                let existing = seen[match]
                let differs = !JobCSV.same(row.job, existing, includeSchedule: portable)
                if differs && !touched.contains(existing.id) && match < state.jobs.count {
                    touched.insert(existing.id)
                    return CSVPreviewRow(row: row, kind: .conflict, existing: existing)
                }
                return CSVPreviewRow(row: row, kind: .duplicate, existing: existing)
            }
            remember(row.job, keys: keys)
            touched.insert(row.job.id)
            return CSVPreviewRow(row: row, kind: .new)
        }
    }

    static func commit(_ preview: [CSVPreviewRow], overwrite: Set<Int>, baseline: [Application],
                       state: inout JobState, now: Date = Date()) throws -> Int {
        guard state.entitlement.hasPro(at: now) else { throw JobError.requiresPro }
        guard state.jobs == baseline else { throw JobError.changed }
        var count = 0
        for item in preview {
            var job = item.row.job
            if item.kind == .new {
                job.events = [StatusEvent(kind: .imported, date: now, status: job.status)]
                state.jobs.append(job)
            } else if item.kind == .conflict, overwrite.contains(item.id), let old = item.existing,
                      let index = state.jobs.firstIndex(where: { $0.id == old.id }) {
                job.id = old.id
                job.events = old.events + [StatusEvent(kind: .imported, date: now, status: job.status)]
                state.jobs[index] = job
            } else { continue }
            count += 1
        }
        return count
    }
}

enum JobCSV {
    static func parse(_ csv: String) throws -> [[String]] {
        enum Mode { case start, plain, quoted, afterQuote }
        var mode = Mode.start
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        let text = csv.first == "\u{FEFF}" ? csv.dropFirst() : csv[...]
        for character in text {
            let newline = character == "\r\n" || character == "\r" || character == "\n"
            if mode == .quoted {
                if character == "\"" { mode = .afterQuote } else { field.append(character) }
                continue
            }
            if mode == .afterQuote && character == "\"" {
                field.append(character)
                mode = .quoted
                continue
            }
            if character == "," || newline {
                row.append(field)
                field = ""
                mode = .start
                if newline { records.append(row); row.removeAll(keepingCapacity: true) }
                continue
            }
            if character == "\"" {
                guard mode == .start else { throw JobError.badCSV }
                mode = .quoted
            } else {
                guard mode != .afterQuote else { throw JobError.badCSV }
                field.append(character)
                mode = .plain
            }
        }
        guard mode != .quoted else { throw JobError.badCSV }
        if mode != .start || !row.isEmpty { records.append(row + [field]) }
        return records
    }

    static func day(_ raw: String) -> Day? {
        if let day = Day(iso: raw) { return day }
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: "/-."))
        guard parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return nil }
        if parts[0].count == 4 { return Day(iso: String(format: "%04d-%02d-%02d", a, b, c)) }
        guard parts[2].count == 4, (1...12).contains(min(a, b)), max(a, b) > 12 || a == b else { return nil }
        return Day(iso: String(format: "%04d-%02d-%02d", c, min(a, b), max(a, b)))
    }

    static func isAmbiguous(_ raw: String) -> Bool {
        let pieces = raw.components(separatedBy: CharacterSet(charactersIn: "/-."))
        guard pieces.count == 3, pieces[2].count == 4, let a = Int(pieces[0]), let b = Int(pieces[1]) else { return false }
        return (1...12).contains(a) && (1...12).contains(b) && a != b
    }

    static func status(_ raw: String) -> JobStatus? {
        switch JobMatching.normalize(raw) {
        case "", "applied", "submitted", "已投递", "已投遞", "已申请", "已申請": return .applied
        case "interview", "interviewing", "面试", "面試": return .interview
        case "rejected", "reject", "已拒绝", "已拒絕", "拒信", "婉拒", "已婉拒": return .rejected
        case "offer", "录用", "錄用", "录取", "錄取", "已获录用", "已獲錄取": return .offer
        case "noreply", "noresponse", "未回复", "未回覆", "无回复", "無回覆": return .noReply
        default: return nil
        }
    }

    static func export(_ jobs: [Application]) -> Data {
        let headers = ["JobFollowUp CSV v1"] + CSVField.allCases.map(\.rawValue)
        let rows = jobs.map { job in
            ["", job.company, job.role, job.source, job.applied?.iso ?? "", job.status.rawValue,
             job.due?.iso ?? "", job.url, job.notes, job.excerpt, job.archived ? "1" : "0",
             job.positionID, job.location, job.id.uuidString, job.follow.manualDate?.iso ?? "",
             job.follow.lastLogged?.iso ?? "", String(job.follow.completed), job.follow.intervals.map(String.init).joined(separator: ";"),
             job.follow.automatic == false ? "0" : "1"]
        }
        let content = ([headers] + rows).map { row in
            row.map { "\"" + escape($0).replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\r\n")
        return Data(("\u{FEFF}" + content + "\r\n").utf8)
    }

    private static func escape(_ value: String) -> String {
        if value.hasPrefix("'") || value.hasPrefix("\t") || value.hasPrefix("\r") || value.hasPrefix("\n")
            || value.trimmed.first.map({ "=+-@＝＋－＠".contains($0) }) == true {
            return "'" + value
        }
        return value
    }

    static func unescape(_ value: String) -> String { value.hasPrefix("'") ? String(value.dropFirst()) : value }

    static func same(_ lhs: Application, _ rhs: Application, includeSchedule: Bool) -> Bool {
        var copy = lhs
        copy.events = rhs.events
        copy.id = rhs.id
        if !includeSchedule {
            if lhs.follow.manualDate == nil && rhs.follow.manualDate != nil { return false }
            if let date = lhs.follow.manualDate, date != rhs.due { return false }
            copy.follow = rhs.follow
        }
        return copy == rhs
    }
}
