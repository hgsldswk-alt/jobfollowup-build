import Foundation

enum JobMatching {
    enum Key: Hashable {
        case title(company: String, role: String)
        case link(String)
        case sitePosition(host: String, position: String)
        case companyPosition(company: String, position: String)
    }

    static func normalize(_ value: String) -> String {
        let folded = value.precomposedStringWithCompatibilityMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let significant = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#"))
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { significant.contains($0) }))
    }

    static func matches(_ lhs: Application, _ rhs: Application) -> Bool {
        !Set(keys(lhs)).isDisjoint(with: keys(rhs))
    }

    static func keys(_ job: Application) -> [Key] {
        var keys: [Key] = []
        let company = normalize(job.company)
        let role = normalize(job.role)
        if !company.isEmpty && !role.isEmpty { keys.append(.title(company: company, role: role)) }
        if let link = linkKey(job.url) { keys.append(.link(link)) }
        let position = normalize(job.positionID)
        if !position.isEmpty {
            if let site = host(job.url) { keys.append(.sitePosition(host: site, position: position)) }
            if !company.isEmpty { keys.append(.companyPosition(company: company, position: position)) }
        }
        return keys
    }

    static func duplicate(of job: Application, in jobs: [Application]) -> Application? {
        jobs.first { $0.id != job.id && matches(job, $0) }
    }

    static func search(_ query: String, state: JobState) -> [Application] {
        let normalized = normalize(query)
        let jobs = state.ordered()
        guard !normalized.isEmpty else { return query.trimmed.isEmpty ? jobs : [] }
        return jobs.filter { normalize($0.company).contains(normalized) || normalize($0.role).contains(normalized) }
    }

    static func host(_ raw: String) -> String? {
        guard let url = URLComponents(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func positionID(_ raw: String) -> String? {
        guard let host = host(raw), let url = URLComponents(string: raw) else { return nil }
        if (host == "linkedin.com" || host.hasSuffix(".linkedin.com")), url.path.contains("/jobs/view/") {
            let slug = url.path.split(separator: "/").last
            guard let id = slug?.split(separator: "-").last, id.allSatisfy(\.isNumber) else { return nil }
            return String(id)
        }
        if host == "indeed.com" || host.hasSuffix(".indeed.com") || host.hasPrefix("indeed.") {
            return url.queryItems?.first { ["jk", "vjk"].contains($0.name.lowercased()) }?.value
        }
        return url.queryItems?.first { ["gh_jid", "jobid", "job_id", "requisitionid"].contains($0.name.lowercased()) }?.value
    }

    private static func linkKey(_ raw: String) -> String? {
        guard let host = host(raw), var url = URLComponents(string: raw) else { return nil }
        if let id = positionID(raw), !id.isEmpty {
            if host == "linkedin.com" || host.hasSuffix(".linkedin.com") { return "linkedin:" + id }
            if host == "indeed.com" || host.hasSuffix(".indeed.com") || host.hasPrefix("indeed.") { return "indeed:" + id }
        }
        url.host = host
        url.scheme = "https"
        url.fragment = nil
        url.user = nil
        url.password = nil
        if url.port == 443 || url.port == 80 { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        let query = (url.queryItems ?? []).filter {
            let key = $0.name.lowercased()
            return !key.hasPrefix("utm_") && !["ref", "refid", "trk", "trackingid", "fbclid", "gclid", "source"].contains(key)
        }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        url.queryItems = query.isEmpty ? nil : query
        guard !url.path.isEmpty || !query.isEmpty else { return nil }
        return url.string
    }
}

struct ShareInput {
    var url = ""
    var title = ""
    var text = ""
    var company = ""
    var role = ""
    var location = ""
    var positionID = ""
}

enum JobShareParser {
    static func parse(_ input: ShareInput, now: Date = Date()) -> Application {
        var job = Application()
        job.applied = Day(now)
        job.company = clean(input.company)
        job.role = clean(input.role)
        job.location = clean(input.location)
        job.url = JobMatching.host(input.url.trimmed) != nil ? input.url.trimmed : links(in: input.text).first ?? ""
        let suppliedID = input.positionID.trimmed
        job.positionID = suppliedID.count <= 180 && !suppliedID.contains(where: \.isNewline) ? suppliedID : ""
        if job.positionID.isEmpty { job.positionID = JobMatching.positionID(job.url) ?? "" }
        let raw = [input.title.trimmed, input.text.trimmed].filter { !$0.isEmpty }
        job.excerpt = Array(Set(raw)).count == 1 ? (raw.first ?? "") : raw.joined(separator: "\n\n")
        if let host = JobMatching.host(job.url) {
            if host == "linkedin.com" || host.hasSuffix(".linkedin.com") || host == "lnkd.in" { job.source = "LinkedIn" }
            else if host.contains("indeed.") { job.source = "Indeed" }
            else { job.source = host }
        }
        let lines = raw.flatMap { $0.components(separatedBy: .newlines) }.map(\.trimmed)
        for line in lines where !line.isEmpty {
            if job.company.isEmpty {
                job.company = capture(#"^(?:company|employer|hiring organization|公司|企業|企业|雇主)\s*[:：]\s*(.+)$"#, line).first ?? ""
            }
            if job.role.isEmpty {
                job.role = capture(#"^(?:role|job title|position|title|岗位|崗位|职位|職位|職缺)\s*[:：]\s*(.+)$"#, line).first ?? ""
            }
            if job.location.isEmpty {
                job.location = capture(#"^(?:location|地点|地點|工作地)\s*[:：]\s*(.+)$"#, line).first ?? ""
            }
        }
        let patterns = [
            #"^(?:subject\s*:\s*)?(?:application received for|your application for|thanks? for applying (?:for|to)|you applied for)\s+(?:the\s+)?(.+?)\s+at\s+(.+?)[.!]?$"#,
            #"^(?:subject\s*:\s*)?(.+?)\s+is hiring\s+(?:an?\s+)?(.+?)(?:\s+in .+)?\s*[|｜]\s*LinkedIn$"#,
            #"^(.+?)\s+(?:at|@)\s+(.+?)(?:\s*[|｜]\s*(?:LinkedIn|Indeed))?$"#,
            #"^(.+?)\s+[-–—]\s+(.+?)\s*[|｜]\s*Indeed$"#,
            #"^(?:已收到|收到)?\s*(.+?)(?:的)?[「『【](.+?)[」』】](?:职位|職缺|職位)?(?:投递|投遞|申请|申請)[。！!]?$"#
        ]
        let bodyLines = input.text.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }
        let titleCandidates = [input.title.trimmed] + (bodyLines.count == 1 ? bodyLines : []) + lines.filter { line in
            let lower = line.lowercased()
            return lower.hasSuffix("| linkedin") || lower.hasSuffix("| indeed")
        }
        for (index, pattern) in patterns.enumerated() {
            let candidates = index == 2 ? titleCandidates : lines
            guard let pair = candidates.lazy.map({ capture(pattern, $0) }).first(where: {
                $0.count == 2 && $0.allSatisfy { clean($0).count > 1 }
            }) else { continue }
            let companyFirst = index == 1 || index == 4
            if job.company.isEmpty { job.company = clean(pair[companyFirst ? 0 : 1]) }
            if job.role.isEmpty { job.role = clean(pair[companyFirst ? 1 : 0]) }
            if index == 0 || index == 4 { job.source = "@email" }
            if index == 1 { job.source = "LinkedIn" }
            if index == 3 { job.source = "Indeed" }
            break
        }
        if job.source.isEmpty && !job.url.isEmpty { job.source = "@website" }
        return job
    }

    private static func clean(_ text: String) -> String {
        let value = text.trimmed
        guard value.count <= 180, !value.contains("@example"), JobMatching.host(value) == nil,
              !value.contains("\n"), !value.contains("://"),
              JobMatching.normalize(value).unicodeScalars.contains(where: CharacterSet.letters.contains) else { return "" }
        return value
    }

    private static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let url = $0.url, JobMatching.host(url.absoluteString) != nil else { return nil }
            return url.absoluteString
        }
    }

    private static func capture(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { clean(String(text[$0])) } }
    }
}
