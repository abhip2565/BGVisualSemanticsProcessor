import Foundation
import SQLite3

/// Handles database schema migrations.
final class MigrationRunner: Sendable {
    static let migrations: [@Sendable (SQLiteConnection) throws -> Void] = [
        { db in
            // Migration 1: v1 schema
            try db.exec("""
            CREATE TABLE schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE visual_semantics_jobs (
                job_id              TEXT PRIMARY KEY,
                item_id             TEXT NOT NULL,
                source_kind         TEXT NOT NULL CHECK(source_kind IN ('fileURL','phAsset')),
                source_value        TEXT NOT NULL,
                owned_file_path     TEXT,
                priority            INTEGER NOT NULL,
                status              TEXT NOT NULL CHECK(status IN
                                      ('pending','processing','completed','failed','cancelled')),
                attempt_count       INTEGER NOT NULL DEFAULT 0,
                next_attempt_at     REAL NOT NULL DEFAULT 0,
                created_at          REAL NOT NULL,
                updated_at          REAL NOT NULL,
                last_error_code     TEXT,
                last_error_message  TEXT,
                last_error_transient INTEGER
            );

            CREATE INDEX idx_jobs_dequeue
              ON visual_semantics_jobs(status, priority DESC, next_attempt_at ASC, created_at ASC);

            CREATE INDEX idx_jobs_stale
              ON visual_semantics_jobs(status, updated_at)
              WHERE status = 'processing';

            CREATE INDEX idx_jobs_item
              ON visual_semantics_jobs(item_id);

            CREATE UNIQUE INDEX uq_jobs_active_per_item
              ON visual_semantics_jobs(item_id)
              WHERE status IN ('pending','processing');

            CREATE TABLE visual_semantics_results (
                item_id         TEXT PRIMARY KEY,
                job_id          TEXT NOT NULL,
                result_json     TEXT NOT NULL,
                result_status   TEXT NOT NULL CHECK(result_status IN ('completed','failed','cancelled')),
                consumed        INTEGER NOT NULL DEFAULT 0,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL,
                expires_at      REAL NOT NULL
            );

            CREATE INDEX idx_results_unconsumed
              ON visual_semantics_results(consumed, created_at)
              WHERE consumed = 0;

            CREATE INDEX idx_results_sweep
              ON visual_semantics_results(expires_at);
            """)
        }
    ]

    static func migrate(connection: SQLiteConnection) throws {
        let tableCheck = try connection.queryInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_meta';") ?? 0
        let current: Int
        if tableCheck == 0 {
            current = 0
        } else {
            current = try connection.queryInt("SELECT value FROM schema_meta WHERE key='schema_version'") ?? 0
        }

        let target = migrations.count
        
        guard current <= target else {
            throw VisualSemanticsError.databaseSchemaIncompatible(have: current, expected: target)
        }
        
        if current == target { return }

        try connection.transaction {
            for v in (current + 1)...target {
                try migrations[v - 1](connection)
            }
            // Use String(target) because schema_meta.value is TEXT
            let updateVersionSQL = "INSERT OR REPLACE INTO schema_meta(key, value) VALUES('schema_version', '\(target)');"
            try connection.exec(updateVersionSQL)
        }
    }
}
