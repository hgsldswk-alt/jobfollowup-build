import Darwin
import Foundation

struct UndoChange: Equatable {
    let before: Application
    let after: Application
}

struct JobStore {
    static let freeLimit = 15
    let directory: URL?
    var preservesTrialAnchor = false

    static var shared: JobStore {
        if Launch.testing {
            return JobStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("UI-Testing", isDirectory: true))
        }
        return JobStore(directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Launch.group),
                        preservesTrialAnchor: true)
    }

    func read(initialize: Bool = true) throws -> JobState {
        try locked(write: false, initialize: initialize) { _ in () }.0
    }

    func update<T>(_ change: (inout JobState) throws -> T) throws -> (JobState, T) {
        try locked(write: true, change)
    }

    private func locked<T>(write: Bool, initialize: Bool = true,
                           _ operation: (inout JobState) throws -> T) throws -> (JobState, T) {
        guard let directory else { throw JobError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("jobs.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw JobError.unavailable }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw JobError.unavailable }
        }
        defer { flock(fd, LOCK_UN) }
        var file = directory.appendingPathComponent("jobs-v1.json")
        let exists = FileManager.default.fileExists(atPath: file.path)
        if !exists && !initialize { throw JobError.unavailable }
        var state = exists ? try JSONDecoder().decode(JobState.self, from: Data(contentsOf: file)) : JobState()
        if !exists && preservesTrialAnchor {
            let firstOpen = TrialAnchor.firstOpen(state.entitlement.firstOpen)
            state.entitlement.firstOpen = firstOpen
        }
        let original = state
        let result = try operation(&state)
        if !exists || (write && state != original) {
            try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
        }
        return (state, result)
    }

    static func save(_ draft: Application, into state: inout JobState, separate: Bool, expected: Application? = nil,
                     now: Date = Date()) throws {
        var job = draft
        job.trimFields()
        guard job.requiredFilled else { throw JobError.invalidFields }
        let index = state.jobs.firstIndex { $0.id == job.id }
        let old = index.map { state.jobs[$0] }
        if let expected, expected != old { throw JobError.changed }
        if !separate, let duplicate = JobMatching.duplicate(of: job, in: state.jobs),
           old.map({ JobMatching.matches($0, duplicate) }) != true { throw JobError.duplicate }
        if job.active && old?.active != true { try checkCapacity(state, now: now) }
        if let index {
            job.events = state.jobs[index].events
            state.jobs[index] = job
        } else {
            job.follow.intervals = state.settings.cadence.intervals
            job.events = [StatusEvent(kind: .created, date: now, status: .applied, localDay: Day(now))]
            state.jobs.append(job)
        }
    }

    static func checkCapacity(_ state: JobState, now: Date) throws {
        if !state.entitlement.hasPro(at: now), state.activeCount() >= freeLimit { throw JobError.cap }
    }

    static func change(_ id: UUID, in state: inout JobState, status: JobStatus? = nil,
                       archive: Bool? = nil, log: Bool = false, now: Date = Date()) throws -> UndoChange? {
        guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { throw JobError.changed }
        let before = state.jobs[index]
        var job = before
        let kind: StatusEvent.Kind
        if let status, job.status != status {
            job.status = status
            if !status.awaiting { job.follow.manualDate = nil }
            kind = .status
        } else if let archive, job.archived != archive {
            job.archived = archive
            kind = archive ? .archived : .restored
        } else if log, job.active, job.due != nil {
            job.follow.manualDate = nil
            job.follow.lastLogged = Day(now)
            job.follow.completed += 1
            kind = .followUp
        } else { return nil }
        if job.active && !before.active { try checkCapacity(state, now: now) }
        job.events.append(StatusEvent(kind: kind, date: now, status: status, localDay: Day(now)))
        state.jobs[index] = job
        return UndoChange(before: before, after: job)
    }

    static func undo(_ change: UndoChange, in state: inout JobState, now: Date = Date()) throws {
        guard let index = state.jobs.firstIndex(where: { $0.id == change.before.id }),
              state.jobs[index] == change.after else { throw JobError.changed }
        if change.before.active && !change.after.active { try checkCapacity(state, now: now) }
        state.jobs[index] = change.before
    }
}
