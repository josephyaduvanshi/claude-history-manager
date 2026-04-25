import Foundation
import GRDB

public enum Database {
    public static func appSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Chronicle", isDirectory: true)
    }

    public static func defaultDatabaseURL() -> URL {
        appSupportDirectory().appendingPathComponent("chronicle.sqlite")
    }

    /// Open or create the on-disk database, applying all migrations.
    ///
    /// SQLite is configured for Chronicle's read-heavy, mostly-append workload:
    ///
    /// - **WAL** journaling so readers never block on the bootstrap writer
    ///   (FSEvents-driven incremental reindex still wants the DB available
    ///   to the menubar / sidebar mid-write).
    /// - **synchronous=NORMAL** trades a tiny window of "last commit may be
    ///   lost on power loss" for ~10× write throughput on the bootstrap
    ///   transaction. Safe per SQLite docs in WAL mode.
    /// - **temp_store=MEMORY** keeps GROUP BY / DISTINCT scratch off disk.
    /// - **mmap_size=128MB** lets large reads page in via the kernel mmap
    ///   path instead of `pread()`, measurable win for the FTS warm path.
    /// - **cache_size=-8000** reserves 8 MiB of page cache (vs. default 2 MiB)
    ///   so the sessions_index B-tree stays hot between queries.
    public static func openDefault() throws -> DatabaseQueue {
        let dir = appSupportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = defaultDatabaseURL()

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA mmap_size = 134217728") // 128MB
            try db.execute(sql: "PRAGMA cache_size = -8000")    // 8MB
        }

        let dbq = try DatabaseQueue(path: url.path, configuration: config)
        try Migrations.all(dbq)
        return dbq
    }
}
