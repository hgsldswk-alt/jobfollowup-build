import CoreImage
import Foundation
import ImageIO
import XCTest

final class CoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testShareFieldsBeatTitleAndKeepPositionNumber() {
        let result = JobShareParser.parse(ShareInput(
            url: "https://www.linkedin.com/jobs/view/designer-9182/?trk=feed",
            title: "Noise at Old Company | LinkedIn", text: "岗位说明\nDescription",
            company: "槐序 Studio", role: "产品 Designer", location: "Tokyo", positionID: "9182"
        ))
        XCTAssertEqual(result.company, "槐序 Studio")
        XCTAssertEqual(result.role, "产品 Designer")
        XCTAssertEqual(result.source, "LinkedIn")
        XCTAssertEqual(result.location, "Tokyo")
        XCTAssertEqual(result.positionID, "9182")
        XCTAssertTrue(result.excerpt.contains("岗位说明"))
    }

    func testShareEmailSiteTitlesAndUnknownLinks() {
        let email = JobShareParser.parse(ShareInput(text: "Subject: Application received for UX Researcher at Cedar Labs.\nThanks!"))
        XCTAssertEqual(email.role, "UX Researcher")
        XCTAssertEqual(email.company, "Cedar Labs")
        XCTAssertEqual(email.source, "@email")
        let linkedIn = JobShareParser.parse(ShareInput(title: "Cedar Labs is hiring a UX Researcher in Tokyo | LinkedIn"))
        XCTAssertEqual(linkedIn.company, "Cedar Labs")
        XCTAssertEqual(linkedIn.role, "UX Researcher")
        let indeed = JobShareParser.parse(ShareInput(title: "Chef - Restaurant Company | Indeed"))
        XCTAssertEqual(indeed.company, "Restaurant Company")
        XCTAssertEqual(indeed.role, "Chef")
        let pasted = JobShareParser.parse(ShareInput(text: "Product Designer at Northline Studio"))
        XCTAssertEqual(pasted.company, "Northline Studio")
        XCTAssertEqual(pasted.role, "Product Designer")
        let mixed = JobShareParser.parse(ShareInput(text: "公司：林间 Studio\n職缺：iOS 工程师"))
        XCTAssertEqual(mixed.company, "林间 Studio")
        XCTAssertEqual(mixed.role, "iOS 工程师")
        let link = JobShareParser.parse(ShareInput(url: "https://www.indeed.com/viewjob?jk=abc"))
        XCTAssertEqual(link.source, "Indeed")
        XCTAssertEqual(link.positionID, "abc")
        XCTAssertFalse(link.requiredFilled)
        XCTAssertFalse(JobShareParser.parse(ShareInput(text: "Hello at 123")).requiredFilled)
        XCTAssertFalse(JobShareParser.parse(ShareInput(text: "https://lnkd.in/xyz")).requiredFilled)
    }

    func testSearchArchiveAndDuplicateNormalization() {
        var a = Application(company: " Ｃafé Studio ", role: "iOS-Engineer", status: .rejected, archived: true)
        var b = Application(company: "CafeStudio", role: "iOS Engineer")
        XCTAssertTrue(JobMatching.matches(a, b))
        XCTAssertEqual(JobMatching.search("café·studio", state: JobState(jobs: [a])).map(\.id), [a.id])
        b.role = "Designer"
        XCTAssertFalse(JobMatching.matches(a, b))
        a.url = "https://www.linkedin.com/jobs/view/programmer-123/?trk=feed"
        b.url = "https://jp.linkedin.com/jobs/view/123?utm_source=xyz"
        XCTAssertTrue(JobMatching.matches(a, b))
        b.url = "https://jp.linkedin.com/jobs/view/456"
        XCTAssertFalse(JobMatching.matches(a, b))
        a.url = "https://example.com/job/open/?utm_campaign=xyz&position=2"
        b.url = "https://www.example.com/job/open?position=2&ref=facebook"
        XCTAssertTrue(JobMatching.matches(a, b))
    }

    func testSevenCalendarDaysAcrossDSTAndFollowUpLifecycle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let applied = try XCTUnwrap(Day(iso: "2026-03-04"))
        var job = Application(company: "A", role: "B", applied: applied)
        XCTAssertEqual(job.follow.due(for: job, calendar: calendar)?.iso, "2026-03-11")
        job.status = .noReply
        XCTAssertEqual(job.follow.due(for: job, calendar: calendar)?.iso, "2026-03-11")
        let due = try XCTUnwrap(Day(iso: "2026-03-12"))
        var state = JobState(jobs: [job])
        XCTAssertEqual(state.due(on: due, calendar: calendar).map(\.id), [job.id])
        let logged = try XCTUnwrap(JobStore.change(job.id, in: &state, log: true, now: try XCTUnwrap(due.date())))
        XCTAssertEqual(state.jobs[0].due?.iso, "2026-03-19")
        try JobStore.undo(logged, in: &state)
        XCTAssertEqual(state.jobs[0].due?.iso, "2026-03-11")
        _ = try JobStore.change(job.id, in: &state, status: .interview)
        XCTAssertNil(state.jobs[0].due)
        state.jobs[0].follow.manualDate = due
        XCTAssertEqual(state.jobs[0].due, due)
        _ = try JobStore.change(job.id, in: &state, status: .offer)
        XCTAssertNil(state.jobs[0].due)
        XCTAssertNil(Application(company: "A", role: "No date", applied: nil).due)
    }

    func testTrialStartsAtFirstOpenAndUsesEarlierVerifiedReceipt() {
        var entitlement = Entitlement(firstOpen: now)
        XCTAssertFalse(Launch.freePeriod)
        XCTAssertTrue(entitlement.hasPro(at: now))
        XCTAssertTrue(entitlement.hasPro(at: now.addingTimeInterval(30 * 86_400 - 1)))
        XCTAssertFalse(entitlement.hasPro(at: now.addingTimeInterval(30 * 86_400)))
        entitlement.verifiedTrial(now.addingTimeInterval(86_400))
        XCTAssertEqual(entitlement.trialStart, now)
        let restored = now.addingTimeInterval(-40 * 86_400)
        entitlement.verifiedTrial(restored)
        entitlement.verifiedTrial(now)
        XCTAssertEqual(entitlement.trialStart, restored)
        XCTAssertFalse(entitlement.hasPro(at: now))
        entitlement.purchasedPro = true
        XCTAssertTrue(entitlement.hasPro(at: now))
        entitlement.purchasedPro = false
        XCTAssertFalse(entitlement.hasPro(at: now))
        let migrated = Entitlement(firstOpen: now, proStartedAt: now.addingTimeInterval(-86_400))
        XCTAssertEqual(migrated.trialStart, now.addingTimeInterval(-86_400))
    }

    func testExpiredLimitKeepsExistingRecordsAndChecksReactivation() throws {
        var state = JobState(entitlement: Entitlement(firstOpen: now.addingTimeInterval(-31 * 86_400)))
        state.jobs = (1...16).map { Application(company: "Company \($0)", role: "Research") }
        let new = Application(company: "Extra", role: "Research")
        XCTAssertThrowsError(try JobStore.save(new, into: &state, separate: false, now: now))
        let original = state.jobs[0]
        var revised = original
        revised.notes = "Still editable"
        try JobStore.save(revised, into: &state, separate: false, expected: original, now: now)
        XCTAssertEqual(state.jobs[0].notes, "Still editable")
        _ = try JobStore.change(original.id, in: &state, status: .rejected, now: now)
        XCTAssertEqual(state.activeCount(), 15)
        XCTAssertThrowsError(try JobStore.change(original.id, in: &state, status: .applied, now: now))
        _ = try JobStore.change(state.jobs[1].id, in: &state, archive: true, now: now)
        try JobStore.save(new, into: &state, separate: false, now: now)
        XCTAssertEqual(state.activeCount(), 15)
        state.entitlement.purchasedPro = true
        _ = try JobStore.change(original.id, in: &state, status: .applied, now: now)
        XCTAssertEqual(state.activeCount(), 16)
    }

    func testConcurrentStoresCheckDuplicateAndCapInsideCommit() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = JobStore(directory: temporary)
        _ = try store.update { state in
            state.entitlement.firstOpen = now.addingTimeInterval(-31 * 86_400)
            state.jobs = (1...14).map { Application(company: "Old \($0)", role: "Research") }
        }
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            let contender = Application(company: "Company \(index)", role: "Research")
            _ = try? JobStore(directory: temporary).update { try JobStore.save(contender, into: &$0, separate: false, now: now) }
        }
        let capped = try store.read()
        XCTAssertEqual(capped.activeCount(), 15)
        XCTAssertEqual(capped.jobs.filter { $0.events.first?.kind == .created }.count, 1)
        _ = try store.update { $0.entitlement.purchasedPro = true }
        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            let contender = Application(company: "Same Company", role: "Same Role")
            _ = try? JobStore(directory: temporary).update { try JobStore.save(contender, into: &$0, separate: false) }
        }
        XCTAssertEqual(try store.read().jobs.filter { $0.company == "Same Company" }.count, 1)
    }

    func testCSVQuotedFieldsBOMFormulaAndStableRoundTrip() throws {
        let raw = "\u{FEFF}公司,職缺,投遞日期,備註,狀態\r\n\"Paper, Inc.\",Designer,,\"One\r\nTwo \"\"quoted\"\"\",未回覆\r\n"
        let file = try CSVImport(Data(raw.utf8))
        let draft = file.row(at: 0, cadence: CadenceTemplate())
        XCTAssertTrue(file.hasRequiredColumns)
        XCTAssertEqual(draft.job.company, "Paper, Inc.")
        XCTAssertEqual(draft.job.notes, "One\r\nTwo \"quoted\"")
        XCTAssertNil(draft.job.applied)
        XCTAssertEqual(draft.job.status, .noReply)
        var job = draft.job
        job.notes = "=HYPERLINK(\"example.com\")"
        job.excerpt = "'original apostrophe"
        job.follow.automatic = false
        let encoded = JobCSV.export([job])
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("'=HYPERLINK"))
        let imported = try CSVImport(encoded)
        let roundTrip = imported.row(at: 0, cadence: CadenceTemplate()).job
        XCTAssertEqual(roundTrip, job)
        XCTAssertEqual(imported.preview(state: JobState(jobs: [job]), corrections: [:], skipping: []).first?.kind, .duplicate)
        XCTAssertThrowsError(try JobCSV.parse("Company,Role\n\"Unclosed"))
    }

    func testCSVConflictsInvalidDatesMappingAndAtomicImport() throws {
        let file = try CSVImport(Data("Company,Role,Applied Date,Status\nA,Engineer,04/05/2026,Applied\nB,Designer,2026-04-06,Offer\nB,Designer,2026-04-06,Offer\nC,Writer,,que?\nD,Editor,2026-02-30,Applied".utf8))
        var state = JobState(jobs: [Application(company: "B", role: "Designer")], entitlement: Entitlement(firstOpen: now))
        let rows = file.preview(state: state, corrections: [:], skipping: [])
        XCTAssertEqual(rows.map(\.kind), [.invalid, .conflict, .duplicate, .invalid, .invalid])
        XCTAssertEqual(rows.first?.row.problems, [.ambiguousDate])
        XCTAssertEqual(rows[3].row.problems, [.status])
        XCTAssertEqual(rows[4].row.problems, [.date])
        let baseline = state.jobs
        XCTAssertEqual(try CSVImport.commit(rows, overwrite: [], baseline: baseline, state: &state, now: now), 0)
        XCTAssertEqual(try CSVImport.commit(rows, overwrite: [1], baseline: baseline, state: &state, now: now), 1)
        XCTAssertEqual(state.jobs[0].id, baseline[0].id)
        XCTAssertEqual(state.jobs[0].status, .offer)
        XCTAssertNil(state.first(.offer))
        XCTAssertThrowsError(try CSVImport.commit(rows, overwrite: [1], baseline: baseline, state: &state, now: now))
        let updated = state.jobs
        XCTAssertThrowsError(try CSVImport.commit(rows, overwrite: [], baseline: updated, state: &state, now: now.addingTimeInterval(31 * 86_400)))
        var custom = try CSVImport(Data("Employer Name,Job Heading\nC,Designer".utf8))
        XCTAssertFalse(custom.hasRequiredColumns)
        custom.mapping[.company] = 0
        custom.mapping[.role] = 1
        XCTAssertEqual(custom.preview(state: state, corrections: [:], skipping: []).first?.kind, .new)
    }

    func testCadenceWhitelistsVersionAndDaysAndLeavesExistingDatesAlone() throws {
        let custom = CadenceTemplate(intervals: [10, 4, 1])
        XCTAssertEqual(try CadenceTemplate.decode(custom.code()), custom)
        XCTAssertThrowsError(try CadenceTemplate.decode("JF2:" + String(repeating: "A", count: 10)))
        XCTAssertThrowsError(try CadenceTemplate.decode("JF1:" + String(repeating: "A", count: 600)))
        XCTAssertThrowsError(try CadenceTemplate(intervals: [0, 12]).code())
        let extra = Data(#"{"version":1,"type":"follow-up","intervals":[7],"pro":true}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertThrowsError(try CadenceTemplate.decode("JF1:" + extra))
        var state = JobState(entitlement: Entitlement(firstOpen: now))
        try JobStore.save(Application(company: "Old", role: "Designer"), into: &state, separate: false, now: now)
        state.settings.cadence = custom
        try JobStore.save(Application(company: "New", role: "Designer"), into: &state, separate: false, now: now)
        XCTAssertEqual(state.jobs.map { $0.follow.intervals }, [[7, 7], [10, 4, 1]])
    }

    func testReminderAggregatesAndStopsAtExpiry() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(Day(iso: "2026-07-01"))
        let noon = try XCTUnwrap(day.date(in: calendar))
        let early = noon.addingTimeInterval(-4 * 3600)
        var job = Application(company: "A", role: "B", applied: day.adding(-7, calendar: calendar))
        var state = JobState(jobs: [job], entitlement: Entitlement(firstOpen: noon.addingTimeInterval(-30 * 86_400)))
        job.id = UUID()
        job.follow.manualDate = day
        state.jobs.append(job)
        let schedule = Reminders.schedule(state, from: early, calendar: calendar)
        XCTAssertEqual(schedule.count, 1)
        XCTAssertEqual(schedule.first?.count, 2)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(schedule.first?.date)), 9)
        XCTAssertTrue(Reminders.schedule(state, from: noon, calendar: calendar).isEmpty)
    }

    func testMilestonesAndReviewNeedValidMilestoneAndThreeDays() throws {
        var state = JobState(entitlement: Entitlement(firstOpen: now))
        let job = Application(company: "A", role: "B", applied: Day(now))
        try JobStore.save(job, into: &state, separate: false, now: now)
        _ = try JobStore.change(job.id, in: &state, status: .interview, now: now)
        XCTAssertNotNil(state.first(.interview))
        XCTAssertFalse(state.canRequestReview(version: "1"))
        let next = now.addingTimeInterval(86_400)
        try JobStore.save(Application(company: "Another", role: "B"), into: &state, separate: false, now: next)
        let later = next.addingTimeInterval(86_400)
        let change = try XCTUnwrap(JobStore.change(job.id, in: &state, status: .offer, now: later))
        XCTAssertNotNil(state.first(.offer))
        XCTAssertTrue(state.canRequestReview(version: "1"))
        state.reviewedVersions.append("1")
        XCTAssertFalse(state.canRequestReview(version: "1"))
        XCTAssertTrue(state.canRequestReview(version: "2"))
        try JobStore.undo(change, in: &state, now: later)
        XCTAssertNil(state.first(.offer))
        XCTAssertFalse(state.canRequestReview(version: "2"))
    }

    func testSharePNGDimensionsQRAndPrivateFields() throws {
        let date = now
        var p = Application(company: "SECRET COMPANY", role: "SECRET ROLE", applied: Day(date), notes: "SECRET NOTES")
        p.events = [StatusEvent(kind: .status, date: date, status: .interview)]
        let counts = ProgressCounts.month(date, jobs: [p])
        XCTAssertEqual(counts, ProgressCounts(applied: 1, interviews: 1, offers: 0))
        let card = ProgressCard(month: "January 2027", counts: counts, downloadURL: Launch.placeholderURL)
        let data = try card.png()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 1080)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 1350)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary as String])
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal as String])
        XCTAssertNil(exif[kCGImagePropertyExifLensModel as String])
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake as String])
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel as String])
        let decoded = try XCTUnwrap(CIImage(data: data))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: decoded).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(messages, [Launch.placeholderURL.absoluteString])
        XCTAssertFalse(card.caption.contains("SECRET"))
        XCTAssertTrue(card.caption.contains(ProgressCard.topics))
    }

    func testUnitBundleContainsEnglishAndLocalizedKeys() {
        XCTAssertNotEqual(L.t("field.company"), "field.company")
        XCTAssertNotEqual(L.t("notification.body"), "notification.body")
    }
}
