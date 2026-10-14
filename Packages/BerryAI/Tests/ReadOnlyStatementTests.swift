import BerryDriverKit
import Testing

@testable import BerryAI

/// What the assistant may run without an approval card. A read sent to the
/// card by mistake costs one click; a write that slips through runs
/// unreviewed, so every statement the classifier cannot prove read-only must
/// come out false.
@Suite("ReadOnlyStatement")
struct ReadOnlyStatementTests {
    private static func sql(_ text: String, driver: DriverID? = .postgres) -> Bool {
        ReadOnlyStatement.isReadOnlySQL(text, driver: driver)
    }

    // MARK: SQL that begins like a read but writes

    @Test(arguments: [
        // A data-modifying CTE, or a WITH clause that leads into a write.
        "WITH d AS (DELETE FROM t WHERE id < 100 RETURNING *) SELECT count(*) FROM d",
        "WITH u AS (UPDATE t SET flag = true RETURNING id) SELECT * FROM u",
        "WITH i AS (INSERT INTO t (id) VALUES (1) RETURNING id) SELECT * FROM i",
        "WITH m AS (MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE RETURNING t.id) SELECT * FROM m",
        "WITH x AS (SELECT 1) DELETE FROM t",
        // EXPLAIN ANALYZE runs the statement it explains.
        "EXPLAIN ANALYZE UPDATE t SET a = 1",
        "EXPLAIN ANALYSE DELETE FROM t",
        "EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM t",
        "EXPLAIN (BUFFERS, ANALYZE true) SELECT * FROM t",
        // SELECT ... INTO creates a table or writes a file on the server.
        "SELECT * INTO backup FROM t",
        "SELECT * FROM t INTO OUTFILE '/tmp/t.csv'",
        // Locking reads.
        "SELECT * FROM t FOR UPDATE",
        "SELECT * FROM t FOR NO KEY UPDATE",
        "SELECT * FROM t FOR SHARE",
        "SELECT * FROM t FOR KEY SHARE",
        "SELECT * FROM t LOCK IN SHARE MODE",
        "SELECT * FROM t WITH (UPDLOCK)",
    ])
    func writeInsideAReadIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    @Test(arguments: [
        "SELECT 1; DELETE FROM t",
        "select id from t; drop table t;",
        "SELECT 1;;",
        "SHOW search_path; SET search_path = evil",
        // A batch whose statements have no separator between them.
        "SELECT 1 DELETE FROM t",
        "SELECT 1 EXEC sp_configure 'show advanced options', 1",
        "SELECT 1 TRUNCATE TABLE t",
        "SELECT 1 BEGIN TRAN",
        "SELECT 1 SET IDENTITY_INSERT t ON",
        "SELECT 1 USE master",
        "SELECT 1 DBCC FREEPROCCACHE",
        "SELECT 1 KILL 52",
        "SELECT 1 DISABLE TRIGGER audit ON t",
        // A write keyword glued to a number or a dot still counts.
        "SELECT 1DELETE FROM t",
        "SELECT 1.DELETE FROM t",
    ])
    func secondStatementIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    /// A write whose literal merely contains a Mongo read method.
    @Test(arguments: [
        "UPDATE t SET note = 'call .find( later' WHERE id = 1",
        "INSERT INTO t (note) VALUES ('x.count(y)')",
        "CREATE TABLE copy AS SELECT '.distinct(' AS c",
    ])
    func writeThatMentionsAMongoReadIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    /// Quoting and comment forms that database engines lex differently. Read
    /// either way, one engine could see a statement boundary the classifier
    /// did not.
    @Test(arguments: [
        #"SELECT 'x\'' ; DELETE FROM t; -- '"#,
        #"SELECT E'x\'' ; DELETE FROM t; -- '"#,
        "SELECT 1 --1; DELETE FROM t",
        "SELECT 1 # '\n; DELETE FROM t; -- '",
        "SELECT 1 /* /* */ ' */ ; DELETE FROM t; -- '",
        "SELECT 1 /*! ; DELETE FROM t */",
        "SELECT 1 /*M! ; DELETE FROM t */",
        "SELECT $a$ ; DELETE FROM t; $a$",
        "SELECT a[']'] ; DELETE FROM t; --']",
        "SELECT [a]]; DELETE FROM t; --]",
        "SELECT @a(') ; DELETE FROM t; --'",
        "SELECT :::a(') ; DELETE FROM t; --'",
        "SELECT 1 -- x\r; DELETE FROM t",
        "SELECT 1 -- x\u{2028}DELETE FROM t",
        "SELECT 1\u{00A0}DELETE FROM t",
        "SELECT 1 \u{0B} FROM t",
        "SELECT 'unterminated",
        "SELECT 1 /* unterminated",
    ])
    func ambiguousLexingIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    /// SQL Server has no EXPLAIN or SHOW statement; a batch that opens with
    /// an unknown word runs it as a stored procedure.
    @Test func explainAndShowAreNotReadsOnSQLServer() {
        #expect(!Self.sql("EXPLAIN SELECT 1", driver: .sqlserver))
        #expect(!Self.sql("SHOW TABLES", driver: .sqlserver))
    }

    // MARK: SQL reads that keep running without a card

    @Test(arguments: [
        "SELECT id, name FROM t WHERE note = 'please delete; then drop table t'",
        "SELECT * FROM t WHERE body LIKE '%insert into%' -- update later",
        "SELECT /* update stats */ count(*) FROM t",
        #"SELECT "update", "delete" FROM t"#,
        "SELECT deleted_at, updated_by FROM t WHERE locked = false",
        "SELECT replace(name, 'a', 'b') FROM t",
        "select count(*) from t;",
        "WITH recent AS (SELECT id FROM t WHERE created_at > now() - interval '1 day') SELECT count(*) FROM recent",
        "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 5) SELECT * FROM r",
        "EXPLAIN SELECT * FROM t WHERE id = 1",
        "EXPLAIN (FORMAT JSON) SELECT 1",
        "EXPLAIN QUERY PLAN SELECT * FROM t",
        "SHOW search_path",
        "SHOW TABLES",
        "SELECT created_at::date, count(*) FROM orders GROUP BY 1",
        "SELECT arr[1], arr[2:3] FROM t",
        "SELECT name FROM users WHERE name = N'Nguyễn Văn A'",
    ])
    func readStaysReadOnly(_ text: String) {
        #expect(Self.sql(text))
    }

    @Test func sqlServerReadsStayReadOnly() {
        #expect(Self.sql("SELECT a.id FROM [Order Details] a", driver: .sqlserver))
        #expect(Self.sql("SELECT TOP 10 * FROM dbo.orders WITH (NOLOCK)", driver: .sqlserver))
        #expect(Self.sql("SELECT @@VERSION", driver: .sqlserver))
    }

    // MARK: Built-in functions with side effects

    @Test(arguments: [
        "SELECT * FROM dblink('host=x', 'SELECT 1') AS r(a int)",
        "SELECT dblink_exec('host=x', 'DROP TABLE t')",
        "SELECT dblink_send_query('c', 'DELETE FROM t')",
        "SELECT * FROM OPENQUERY(remote, 'SELECT 1')",
        "SELECT * FROM OPENROWSET('SQLNCLI', 'Server=x;', 'SELECT 1')",
        "SELECT * FROM OPENDATASOURCE('SQLNCLI', 'Data Source=x').db.dbo.t",
        "SELECT query_to_xml('SELECT 1', true, false, '')",
    ])
    func remoteOrPassThroughExecutionIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    @Test(arguments: [
        "SELECT pg_terminate_backend(42)",
        "SELECT pg_cancel_backend(42)",
        "SELECT pg_reload_conf()",
        "SELECT pg_rotate_logfile()",
        "SELECT set_config('search_path', 'other', false)",
        "SELECT pg_catalog.set_config('role', 'admin', false)",
        "SELECT pg_notify('channel', 'payload')",
        "SELECT pg_stat_reset()",
        "SELECT pg_switch_wal()",
        "SELECT pg_create_logical_replication_slot('s', 'pgoutput')",
    ])
    func processOrSessionControlIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    @Test(arguments: [
        "SELECT nextval('orders_id_seq')",
        "SELECT setval('orders_id_seq', 1)",
        "SELECT NEXT VALUE FOR dbo.order_numbers",
        "SELECT order_seq.nextval FROM dual",
    ])
    func sequenceAdvanceIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    @Test(arguments: [
        "SELECT lo_import('/etc/hosts')",
        "SELECT lo_export(16409, '/tmp/x')",
        "SELECT lo_unlink(16409)",
        "SELECT lo_create(0)",
        "SELECT pg_read_file('postgresql.conf')",
        "SELECT pg_read_binary_file('x')",
        "SELECT pg_ls_dir('.')",
        "SELECT pg_stat_file('x')",
        "SELECT LOAD_FILE('/etc/hosts')",
    ])
    func largeObjectOrServerFileIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    @Test(arguments: [
        "SELECT pg_advisory_lock(1)",
        "SELECT pg_advisory_xact_lock_shared(1)",
        "SELECT pg_try_advisory_lock(1)",
        "SELECT pg_advisory_unlock_all()",
        "SELECT GET_LOCK('x', 10)",
        "SELECT RELEASE_LOCK('x')",
        "SELECT RELEASE_ALL_LOCKS()",
        "SELECT pg_sleep(10)",
        "SELECT pg_sleep_for('5 minutes')",
        "SELECT SLEEP(10)",
        "SELECT BENCHMARK(1000000000, MD5('x'))",
        "SELECT 1 WAITFOR DELAY '01:00:00'",
    ])
    func lockOrSleepIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    @Test(arguments: [
        "SELECT load_extension('/tmp/x')",
        "SELECT writefile('/tmp/x', 'y')",
        "SELECT xp_cmdshell('dir')",
        "SELECT master.dbo.xp_regread('x')",
        "SELECT sp_executesql(N'DELETE FROM t')",
        "SELECT sp_OACreate('x')",
    ])
    func extensionOrShellIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    /// Extension and engine functions that delete rows, change schema,
    /// schedule work, call out of the database or reconfigure a cluster when
    /// a plain SELECT calls them.
    @Test(arguments: [
        // TimescaleDB.
        "SELECT drop_chunks('metrics', INTERVAL '3 months')",
        "SELECT add_retention_policy('metrics', INTERVAL '90 days')",
        "SELECT remove_compression_policy('metrics')",
        "SELECT create_hypertable('metrics', 'time')",
        "SELECT compress_chunk(c) FROM show_chunks('metrics') c",
        "SELECT add_job('cleanup', '1 day')",
        "SELECT alter_job(1000, scheduled => false)",
        "SELECT delete_job(1000)",
        // PostGIS.
        "SELECT DropGeometryTable('public', 'parcels')",
        "SELECT DropGeometryColumn('parcels', 'geom')",
        "SELECT AddGeometryColumn('parcels', 'geom', 4326, 'POINT', 2)",
        "SELECT UpdateGeometrySRID('parcels', 'geom', 3857)",
        "SELECT Populate_Geometry_Columns()",
        "SELECT topology.CreateTopology('roads', 4326)",
        "SELECT topology.TopoGeo_AddPoint('roads', 'POINT(0 0)')",
        "SELECT DropRasterConstraints('elevation', 'rast')",
        // pg_cron.
        "SELECT cron.schedule('nightly', '0 3 * * *', 'TRUNCATE logs')",
        "SELECT cron.unschedule('nightly')",
        // Amazon RDS and Aurora.
        "SELECT aws_s3.table_import_from_s3('t', '', '(format csv)', aws_commons.create_s3_uri('b', 'k', 'us-east-1'))",
        "SELECT * FROM aws_lambda.invoke(aws_commons.create_lambda_function_arn('f'), '{}'::json)",
        // Citus and pg_partman.
        "SELECT create_distributed_table('events', 'tenant_id')",
        "SELECT citus_add_node('worker-1', 5432)",
        "SELECT partman.run_maintenance()",
        // HTTP from the server, and pg_surgery.
        "SELECT * FROM http_post('https://example.invalid', 'x', 'text/plain')",
        "SELECT net.http_get('https://example.invalid')",
        "SELECT heap_force_kill('t'::regclass, tids) FROM damaged",
        // MySQL replication administration and the locking service.
        "SELECT group_replication_set_as_primary('00000000-0000-0000-0000-000000000000')",
        "SELECT group_replication_switch_to_single_primary_mode()",
        "SELECT asynchronous_connection_failover_add_source('ch', 'h', 3306, '', 50)",
        "SELECT service_get_write_locks('ns', 'lock1', 10)",
        "SELECT version_tokens_lock_exclusive('t', 10)",
    ])
    func extensionWriteOrAdministrationIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    /// Session state, waits and index maintenance that a read can reach.
    @Test(arguments: [
        "SELECT LAST_INSERT_ID(42)",
        "SELECT @total := @total + amount FROM orders",
        "SELECT MASTER_GTID_WAIT('0-1-100', 10)",
        "SELECT pg_switch_xlog()",
        "SELECT pg_xlog_replay_pause()",
        "SELECT pg_xlog_replay_resume()",
        "SELECT gin_clean_pending_list('docs_body_idx')",
        "SELECT brin_summarize_new_values('events_ts_idx')",
        "SELECT brin_summarize_range('events_ts_idx', 0)",
        "SELECT brin_desummarize_range('events_ts_idx', 0)",
    ])
    func sessionStateOrIndexMaintenanceIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    /// Reads from the same extensions and engines keep running without a card.
    @Test(arguments: [
        "SELECT LAST_INSERT_ID()",
        "SELECT time_bucket('1 day', ts), avg(v) FROM metrics GROUP BY 1",
        "SELECT * FROM show_chunks('metrics')",
        "SELECT hypertable_size('metrics')",
        "SELECT ST_AsText(geom), ST_Area(geom) FROM parcels",
        "SELECT Find_SRID('public', 'parcels', 'geom')",
        "SELECT group_replication_get_write_concurrency()",
        "SELECT make_interval(days => 10)",
        "SELECT ADDDATE(created_at, 1), ADDTIME(t, '01:00') FROM orders",
    ])
    func extensionReadStaysReadOnly(_ text: String) {
        #expect(Self.sql(text))
    }

    /// Call forms that keep the function's name from reading as a plain word.
    @Test(arguments: [
        #"SELECT "nextval"('s')"#,
        "SELECT `sleep`(10)",
        "SELECT [xp_cmdshell]('dir')",
        "SELECT pg_sleep/* pause */(10)",
        "SELECT SLEEP (10)",
    ])
    func disguisedSideEffectCallIsNotReadOnly(_ text: String) {
        #expect(!Self.sql(text))
    }

    @Test(arguments: [
        "SELECT count(*), sum(amount), avg(amount), max(id) FROM orders",
        "SELECT coalesce(name, 'n/a'), lower(email), upper(code), length(note) FROM users",
        "SELECT now(), current_date, date_trunc('day', created_at) FROM orders",
        "SELECT json_extract(data, '$.a'), jsonb_build_object('id', id), json_agg(name) FROM events GROUP BY id",
        "SELECT data->>'name', to_char(created_at, 'YYYY-MM') FROM events",
        "SELECT currval('orders_id_seq')",
        "SELECT pg_size_pretty(pg_total_relation_size('orders')), pg_backend_pid()",
        "SELECT sleep_minutes, next_value, lower_bound FROM shifts",
    ])
    func ordinaryFunctionStaysReadOnly(_ text: String) {
        #expect(Self.sql(text))
    }

    // MARK: Cost

    /// Classification runs on the main actor before any query timeout, so its
    /// work stays linear in the length of the text. A chain of casts used to
    /// make every `:` rescan the rest of the chain.
    @Test func longCastChainIsLexedInLinearSteps() {
        let chain = "SELECT x" + String(repeating: "::a", count: 3_000) + " FROM t"
        #expect(Self.sql(chain))
        #expect(ReadOnlyStatement.sqlLexingSteps(chain) <= 5 * chain.unicodeScalars.count)
    }

    @Test func longOrdinarySelectIsLexedInLinearSteps() {
        let columns = (1...3_000).map { "c\($0)" }.joined(separator: ", ")
        let select = "SELECT \(columns) FROM t WHERE note = 'a [b] -- c'"
        #expect(Self.sql(select))
        #expect(ReadOnlyStatement.sqlLexingSteps(select) <= 5 * select.unicodeScalars.count)
    }

    // MARK: Mongo shell

    @Test(arguments: [
        #"db.users.deleteMany({note: ".find("})"#,
        #"db.users.updateOne({tag: ".count("}, {$set: {seen: true}})"#,
        #"db.users.insertOne({q: ".distinct("})"#,
        "db.users.find({}); db.users.deleteMany({})",
        "db.users.find({}).forEach(function(d) { db.users.remove(d) })",
        #"db.users.aggregate([{$match: {}}, {$out: "copy"}])"#,
        #"db.users.aggregate([{"$merge": {into: "copy"}}])"#,
        "db.users.aggregate([{'$out': 'copy'}])",
        "db.users.aggregate([{\"$out\u{0}\": \"copy\"}])",
        // Elasticsearch and Qdrant scripts reach the same path.
        #"{"index": "logs", "op": "delete_by_query", "query": {"match": {"msg": ".find("}}}"#,
        #"{"collection": "docs", "op": "delete", "ids": [1], "note": ".count("}"#,
    ])
    func mongoWriteIsNotReadOnly(_ text: String) {
        #expect(!ReadOnlyStatement.isReadOnlyMongoShell(text))
    }

    /// Forms the executor's statement splitter reads differently from its
    /// lexer, and calls it does not resolve.
    @Test(arguments: [
        "db.users.find({}) // .count(",
        "db.users.find({}) /* .count( */",
        #"db.users.find({a: "\"; db.users.deleteMany({}); \""})"#,
        #"db.getSiblingDB("admin").users.find({})"#,
        // The shell resolver has no `count`.
        "db.users.count({active: true})",
    ])
    func unrecognizedMongoIsNotReadOnly(_ text: String) {
        #expect(!ReadOnlyStatement.isReadOnlyMongoShell(text))
    }

    @Test(arguments: [
        #"db.users.find({note: "deleteMany"})"#,
        #"db.users.find({status: "A"}).sort({created: -1}).limit(5)"#,
        #"db.orders.aggregate([{$match: {status: "A"}}, {$group: {_id: "$cust", total: {$sum: "$amount"}}}])"#,
        #"db.users.distinct("city")"#,
        "db.users.find({});",
    ])
    func mongoReadStaysReadOnly(_ text: String) {
        #expect(ReadOnlyStatement.isReadOnlyMongoShell(text))
    }

    @Test(arguments: [
        #"db.users.findOne({_id: ObjectId("507f1f77bcf86cd799439011")})"#,
        "db.users.countDocuments({active: true})",
        "db.users.estimatedDocumentCount()",
    ])
    func everyMongoReadMethodIsReadOnly(_ text: String) {
        #expect(ReadOnlyStatement.isReadOnlyMongoShell(text))
    }
}
